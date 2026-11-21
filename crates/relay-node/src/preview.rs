//! Link previews for the web client: `GET /v1/preview?url=`.
//!
//! The node fetches the page with [`GuardedClient`] (public addresses only, checked on every
//! redirect), reads Open Graph, Twitter card, `<title>` and `<meta name=description>`, and
//! turns `og:image` into a small JPEG data URL. Results are cached in memory for 10 minutes.
//! URLs are never logged.

use std::io::Cursor;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use image::{DynamicImage, ImageFormat, ImageReader, Limits};
use lru::LruCache;
use reqwest::Url;
use serde::Serialize;
use tokio::sync::Semaphore;

use crate::netguard::{FetchError, GuardedClient};
use crate::ratelimit::IpLimiter;

/// Whole-fetch timeout (page, then image), redirects included.
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(8);
/// Largest page or image body read.
pub const MAX_BODY: usize = 2 * 1024 * 1024;
/// Largest image in a preview.
pub const MAX_IMAGE_BYTES: usize = 40 * 1024;
/// Longest side of a preview image.
pub const IMAGE_SIDE: u32 = 600;
const CACHE_TTL: Duration = Duration::from_secs(600);
const CACHE_SIZE: usize = 512;
const MAX_URL_LEN: usize = 2048;
/// Previews per client IP: 1 every 2 s, burst 20.
const RATE_PER_SEC: f64 = 0.5;
const RATE_BURST: f64 = 20.0;
/// Previews fetched at once across all clients.
const MAX_INFLIGHT: usize = 16;

/// The JSON answer.
#[derive(Debug, Clone, Serialize, Default, PartialEq)]
pub struct Preview {
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub site: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
}

/// Why no preview could be built.
#[derive(Debug, PartialEq, Eq)]
pub enum PreviewError {
    BadUrl,
    Blocked,
    Failed,
    Busy,
}

pub struct Previewer {
    cache: Mutex<LruCache<String, (Instant, Arc<Preview>)>>,
    pub(crate) limiter: IpLimiter,
    inflight: Semaphore,
}

impl Default for Previewer {
    fn default() -> Self {
        Self {
            cache: Mutex::new(LruCache::new(NonZeroUsize::new(CACHE_SIZE).unwrap())),
            limiter: IpLimiter::new(RATE_PER_SEC, RATE_BURST),
            inflight: Semaphore::new(MAX_INFLIGHT),
        }
    }
}

/// Parses the `url` query value: http(s) only, no credentials, bounded length.
pub fn parse_target(raw: &str) -> Option<Url> {
    if raw.len() > MAX_URL_LEN {
        return None;
    }
    let mut url = Url::parse(raw.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https") || url.host().is_none() {
        return None;
    }
    url.set_fragment(None);
    Some(url)
}

impl Previewer {
    fn cached(&self, key: &str) -> Option<Arc<Preview>> {
        let mut c = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        match c.get(key) {
            Some((at, p)) if at.elapsed() < CACHE_TTL => Some(p.clone()),
            Some(_) => {
                c.pop(key);
                None
            }
            None => None,
        }
    }

    /// Builds (or returns the cached) preview of `url`.
    pub async fn preview(&self, net: &GuardedClient, url: Url) -> Result<Arc<Preview>, PreviewError> {
        let key = url.as_str().to_string();
        if let Some(p) = self.cached(&key) {
            return Ok(p);
        }
        let _permit = self.inflight.try_acquire().map_err(|_| PreviewError::Busy)?;
        let p = Arc::new(build(net, url).await?);
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).put(key, (Instant::now(), p.clone()));
        Ok(p)
    }
}

fn map_fetch(e: FetchError) -> PreviewError {
    match e {
        FetchError::BadUrl => PreviewError::BadUrl,
        FetchError::Blocked => PreviewError::Blocked,
        _ => PreviewError::Failed,
    }
}

fn content_type(h: &reqwest::header::HeaderMap) -> String {
    h.get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase()
}

async fn build(net: &GuardedClient, url: Url) -> Result<Preview, PreviewError> {
    let page = net
        .get(url.clone(), "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", MAX_BODY, FETCH_TIMEOUT)
        .await
        .map_err(map_fetch)?;
    if !page.status.is_success() {
        return Err(PreviewError::Failed);
    }
    let ct = content_type(&page.headers);
    if !(ct.contains("html") || ct.is_empty()) {
        return Err(PreviewError::Failed);
    }
    let final_url = page.url.clone();
    let body = page.body;
    let meta = tokio::task::spawn_blocking(move || parse_html(&String::from_utf8_lossy(&body)))
        .await
        .map_err(|_| PreviewError::Failed)?;

    let site = meta
        .site
        .or_else(|| final_url.host_str().map(|h| h.trim_start_matches("www.").to_string()));
    let mut image = None;
    if let Some(img_url) = meta.image.as_deref().and_then(|s| final_url.join(s).ok())
        && let Ok(img) = net.get(img_url, "image/*", MAX_BODY, FETCH_TIMEOUT).await
        && img.status.is_success()
        && content_type(&img.headers).starts_with("image/")
    {
        image = tokio::task::spawn_blocking(move || shrink_image(&img.body)).await.ok().flatten();
    }
    Ok(Preview { url: url.to_string(), title: meta.title, description: meta.description, site, image })
}

/// Metadata read from a page.
#[derive(Debug, Default, PartialEq)]
pub struct PageMeta {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site: Option<String>,
    pub image: Option<String>,
}

fn clean(s: &str, max: usize) -> Option<String> {
    let s: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.is_empty() {
        return None;
    }
    Some(if s.chars().count() > max { format!("{}…", s.chars().take(max).collect::<String>()) } else { s })
}

/// Reads Open Graph, Twitter card, `<title>` and `<meta name=description>`. The first
/// non-empty value wins, in that order of preference.
pub fn parse_html(html: &str) -> PageMeta {
    use scraper::{Html, Selector};
    let doc = Html::parse_document(html);
    let meta_sel = Selector::parse("meta").unwrap();
    let mut tags: Vec<(String, String)> = Vec::new();
    for el in doc.select(&meta_sel) {
        let v = el.value();
        let Some(content) = v.attr("content") else { continue };
        let key = v.attr("property").or_else(|| v.attr("name")).unwrap_or("").trim().to_ascii_lowercase();
        if !key.is_empty() {
            tags.push((key, content.to_string()));
        }
    }
    let first = |keys: &[&str], max: usize| {
        keys.iter().find_map(|k| tags.iter().find(|(n, c)| n == k && !c.trim().is_empty()).and_then(|(_, c)| clean(c, max)))
    };
    let title_tag = Selector::parse("title").unwrap();
    let title = first(&["og:title", "twitter:title"], 300)
        .or_else(|| doc.select(&title_tag).next().and_then(|t| clean(&t.text().collect::<String>(), 300)));
    PageMeta {
        title,
        description: first(&["og:description", "twitter:description", "description"], 1000),
        site: first(&["og:site_name"], 100),
        image: first(&["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"], MAX_URL_LEN),
    }
}

fn data_url(mime: &str, bytes: &[u8]) -> String {
    format!("data:{mime};base64,{}", STANDARD.encode(bytes))
}

/// Turns image bytes into a data URL of at most [`MAX_IMAGE_BYTES`]: the original when it is
/// already a small JPEG, PNG or WebP within 600 px, else a JPEG shrunk to 600 px or less,
/// lowering quality and size until it fits. `None` when it never fits or does not decode.
pub fn shrink_image(bytes: &[u8]) -> Option<String> {
    let format = image::guess_format(bytes).ok()?;
    if !matches!(format, ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::WebP | ImageFormat::Gif) {
        return None;
    }
    let reader = || {
        let mut r = ImageReader::with_format(Cursor::new(bytes), format);
        let mut limits = Limits::default();
        limits.max_image_width = Some(12_000);
        limits.max_image_height = Some(12_000);
        limits.max_alloc = Some(256 * 1024 * 1024);
        r.limits(limits);
        r
    };
    let (w, h) = reader().into_dimensions().ok()?;
    if bytes.len() <= MAX_IMAGE_BYTES && w <= IMAGE_SIDE && h <= IMAGE_SIDE {
        let mime = match format {
            ImageFormat::Jpeg => Some("image/jpeg"),
            ImageFormat::Png => Some("image/png"),
            ImageFormat::WebP => Some("image/webp"),
            _ => None,
        };
        if let Some(mime) = mime {
            return Some(data_url(mime, bytes));
        }
    }
    let img = reader().decode().ok()?;
    for (side, qualities) in [(IMAGE_SIDE, &[82u8, 70, 58, 46][..]), (450, &[60, 45][..]), (300, &[60, 40][..])] {
        let rgb = flatten(&fit(&img, side));
        for &q in qualities {
            let mut out = Vec::new();
            let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, q);
            if rgb.write_with_encoder(enc).is_err() {
                return None;
            }
            if out.len() <= MAX_IMAGE_BYTES {
                return Some(data_url("image/jpeg", &out));
            }
        }
    }
    None
}

fn fit(img: &DynamicImage, side: u32) -> DynamicImage {
    if img.width() <= side && img.height() <= side {
        img.clone()
    } else {
        img.resize(side, side, image::imageops::FilterType::Triangle)
    }
}

/// RGB on a white background (JPEG has no alpha).
fn flatten(img: &DynamicImage) -> image::RgbImage {
    let rgba = img.to_rgba8();
    image::RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let p = rgba.get_pixel(x, y).0;
        let a = p[3] as u32;
        let mix = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        image::Rgb([mix(p[0]), mix(p[1]), mix(p[2])])
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_og_then_fallbacks() {
        let m = parse_html(
            r#"<html><head><title> Plain   title </title>
            <meta name="description" content="plain description">
            <meta property="og:title" content="OG title">
            <meta property="og:image" content="/img/card.png">
            <meta property="og:site_name" content="Example">
            </head><body>x</body></html>"#,
        );
        assert_eq!(m.title.as_deref(), Some("OG title"));
        assert_eq!(m.description.as_deref(), Some("plain description"));
        assert_eq!(m.site.as_deref(), Some("Example"));
        assert_eq!(m.image.as_deref(), Some("/img/card.png"));

        let m = parse_html(
            r#"<title>Only &amp; title</title><meta name="twitter:description" content="tw"><meta name="twitter:image" content="https://x/i.jpg">"#,
        );
        assert_eq!(m.title.as_deref(), Some("Only & title"));
        assert_eq!(m.description.as_deref(), Some("tw"));
        assert_eq!(m.image.as_deref(), Some("https://x/i.jpg"));
        assert_eq!(m.site, None);
        assert_eq!(parse_html("no markup at all"), PageMeta::default());
    }

    #[test]
    fn targets() {
        assert!(parse_target("https://example.org/a#frag").is_some_and(|u| u.fragment().is_none()));
        assert!(parse_target("javascript:alert(1)").is_none());
        assert!(parse_target("ftp://example.org").is_none());
        assert!(parse_target(&format!("https://e.org/{}", "a".repeat(3000))).is_none());
    }

    fn noisy_png(w: u32, h: u32) -> Vec<u8> {
        let mut seed = 1u32;
        let img = image::RgbaImage::from_fn(w, h, |_, _| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            let b = seed.to_le_bytes();
            image::Rgba([b[0], b[1], b[2], 255])
        });
        let mut out = Vec::new();
        DynamicImage::ImageRgba8(img).write_to(&mut Cursor::new(&mut out), ImageFormat::Png).unwrap();
        out
    }

    fn decode_data_url(s: &str) -> (String, Vec<u8>) {
        let (head, data) = s.split_once(";base64,").unwrap();
        (head.trim_start_matches("data:").to_string(), STANDARD.decode(data).unwrap())
    }

    #[test]
    fn shrinks_big_images_and_keeps_small_ones() {
        // Small PNG: kept as is.
        let small = noisy_png(20, 10);
        let (mime, bytes) = decode_data_url(&shrink_image(&small).unwrap());
        assert_eq!((mime.as_str(), bytes), ("image/png", small));

        // Big noisy PNG: JPEG, <= 600 px, <= 40 KiB.
        let big = noisy_png(1600, 900);
        let (mime, bytes) = decode_data_url(&shrink_image(&big).unwrap());
        assert_eq!(mime, "image/jpeg");
        assert!(bytes.len() <= MAX_IMAGE_BYTES, "{} bytes", bytes.len());
        let img = image::load_from_memory(&bytes).unwrap();
        assert!(img.width() <= IMAGE_SIDE && img.height() <= IMAGE_SIDE);

        assert_eq!(shrink_image(b"not an image"), None);
    }
}
