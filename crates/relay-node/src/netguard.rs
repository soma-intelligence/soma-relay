//! Outbound HTTP for user-supplied URLs (link previews, Web Push endpoints) without SSRF.
//!
//! Every hop is checked: scheme http/https, port 80/443, and every address the host
//! resolves to must be public. DNS is resolved by the node itself (a custom reqwest
//! resolver that drops non-public addresses), so reqwest can only connect to addresses that
//! passed the check. IP literal hosts are checked before the request. Redirects are followed
//! by hand, at most 5, each one checked again.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::Bytes;
use futures_util::StreamExt;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::header::{HeaderMap, LOCATION};
use reqwest::{Method, StatusCode, Url};

/// Most redirects followed for one fetch.
pub const MAX_REDIRECTS: usize = 5;

/// Why an outbound request was refused or failed.
#[derive(Debug, PartialEq, Eq)]
pub enum FetchError {
    /// Not http/https, a port other than 80/443, credentials in the URL, or no host.
    BadUrl,
    /// The host is, or resolves only to, a private, loopback, link-local or reserved address.
    Blocked,
    /// More than [`MAX_REDIRECTS`] redirects, or a redirect without a usable `Location`.
    TooManyRedirects,
    /// The body is over the size cap.
    TooLarge,
    /// DNS, connect, TLS or timeout failure.
    Network,
}

/// True when `ip` is a globally routable unicast address a node may connect to.
pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    let blocked = o[0] == 0                                   // 0.0.0.0/8
        || o[0] == 10                                         // 10/8
        || (o[0] == 100 && (o[1] & 0xc0) == 64)              // 100.64/10 (CGNAT)
        || o[0] == 127                                        // loopback
        || (o[0] == 169 && o[1] == 254)                      // link-local, cloud metadata
        || (o[0] == 172 && (o[1] & 0xf0) == 16)              // 172.16/12
        || (o[0] == 192 && o[1] == 168)                      // 192.168/16
        || (o[0] == 192 && o[1] == 0 && o[2] == 0)           // 192.0.0/24 (IETF protocol)
        || (o[0] == 192 && o[1] == 0 && o[2] == 2)           // TEST-NET-1
        || (o[0] == 198 && (o[1] & 0xfe) == 18)              // 198.18/15 (benchmarking)
        || (o[0] == 198 && o[1] == 51 && o[2] == 100)        // TEST-NET-2
        || (o[0] == 203 && o[1] == 0 && o[2] == 113)         // TEST-NET-3
        || o[0] >= 224; // 224/4 multicast, 240/4 reserved, broadcast
    !blocked
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d), NAT64 (64:ff9b::/96) and
    // 6to4 (2002::/16) all embed an IPv4 address: judge that address instead.
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let s = ip.segments();
    if s[..6] == [0, 0, 0, 0, 0, 0] {
        // ::, ::1 and the deprecated IPv4-compatible form.
        let v4 = Ipv4Addr::new((s[6] >> 8) as u8, s[6] as u8, (s[7] >> 8) as u8, s[7] as u8);
        return !ip.is_unspecified() && !ip.is_loopback() && is_public_v4(v4);
    }
    if s[0] == 0x64 && s[1] == 0xff9b && s[2..6] == [0, 0, 0, 0] {
        let v4 = Ipv4Addr::new((s[6] >> 8) as u8, s[6] as u8, (s[7] >> 8) as u8, s[7] as u8);
        return is_public_v4(v4);
    }
    if s[0] == 0x2002 {
        let v4 = Ipv4Addr::new((s[1] >> 8) as u8, s[1] as u8, (s[2] >> 8) as u8, s[2] as u8);
        return is_public_v4(v4);
    }
    let blocked = (s[0] & 0xfe00) == 0xfc00      // fc00::/7 unique local
        || (s[0] & 0xffc0) == 0xfe80             // fe80::/10 link-local
        || (s[0] & 0xffc0) == 0xfec0             // fec0::/10 site-local (deprecated)
        || (s[0] & 0xff00) == 0xff00             // ff00::/8 multicast
        || (s[0] == 0x2001 && s[1] == 0x0db8)    // documentation
        || (s[0] == 0x0100 && s[1..4] == [0, 0, 0]); // 100::/64 discard
    !blocked
}

/// Address policy shared by the resolver and the URL checks.
#[derive(Default)]
pub struct Policy {
    /// Tests only: also allow 127.0.0.0/8 on any port, over plain http.
    allow_loopback: AtomicBool,
}

impl Policy {
    pub(crate) fn loopback_ok(&self) -> bool {
        self.allow_loopback.load(Ordering::Relaxed)
    }

    /// Whether the node may connect to `ip`.
    pub fn ip_allowed(&self, ip: IpAddr) -> bool {
        is_public_ip(ip) || (self.loopback_ok() && matches!(ip, IpAddr::V4(v4) if v4.is_loopback()))
    }

    /// Checks scheme, credentials and port, and an IP literal host. Hostnames are checked by
    /// the resolver when the request connects.
    pub fn check_url(&self, url: &Url) -> Result<(), FetchError> {
        if !matches!(url.scheme(), "http" | "https") || !url.username().is_empty() || url.password().is_some() {
            return Err(FetchError::BadUrl);
        }
        let port = url.port_or_known_default().ok_or(FetchError::BadUrl)?;
        if !self.loopback_ok() && port != 80 && port != 443 {
            return Err(FetchError::BadUrl);
        }
        match url.host() {
            None => Err(FetchError::BadUrl),
            Some(url::Host::Ipv4(ip)) => self.ip_check(IpAddr::V4(ip)),
            Some(url::Host::Ipv6(ip)) => self.ip_check(IpAddr::V6(ip)),
            Some(url::Host::Domain(d)) => {
                // A trailing-dot or bracket-free numeric host that the URL parser left as a
                // domain (non-special schemes) is still an address: check it as one.
                match d.trim_end_matches('.').parse::<IpAddr>() {
                    Ok(ip) => self.ip_check(ip),
                    Err(_) if d.is_empty() => Err(FetchError::BadUrl),
                    Err(_) => Ok(()),
                }
            }
        }
    }

    fn ip_check(&self, ip: IpAddr) -> Result<(), FetchError> {
        if self.ip_allowed(ip) { Ok(()) } else { Err(FetchError::Blocked) }
    }
}

/// reqwest resolver that resolves with the system resolver and keeps only allowed addresses.
struct GuardedResolver {
    policy: Arc<Policy>,
}

#[derive(Debug)]
struct BlockedHost;

impl std::fmt::Display for BlockedHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("host resolves only to non-public addresses")
    }
}

impl std::error::Error for BlockedHost {}

impl Resolve for GuardedResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let policy = self.policy.clone();
        Box::pin(async move {
            let host = name.as_str().to_string();
            let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0)).await?.collect();
            let allowed: Vec<SocketAddr> = addrs.into_iter().filter(|a| policy.ip_allowed(a.ip())).collect();
            if allowed.is_empty() {
                return Err(Box::new(BlockedHost) as Box<dyn std::error::Error + Send + Sync>);
            }
            Ok(Box::new(allowed.into_iter()) as Addrs)
        })
    }
}

/// A finished response: final URL, status, headers and the (capped) body.
pub struct Fetched {
    pub url: Url,
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Bytes,
}

/// HTTP client for user-supplied URLs.
pub struct GuardedClient {
    policy: Arc<Policy>,
    client: reqwest::Client,
}

impl GuardedClient {
    pub fn new(user_agent: &str) -> Self {
        let policy = Arc::new(Policy::default());
        let client = reqwest::Client::builder()
            .user_agent(user_agent)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .dns_resolver(Arc::new(GuardedResolver { policy: policy.clone() }))
            .connect_timeout(Duration::from_secs(5))
            .pool_max_idle_per_host(2)
            .build()
            .expect("reqwest client");
        Self { policy, client }
    }

    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    /// Tests only: lets the client reach 127.0.0.0/8 on any port.
    #[doc(hidden)]
    pub fn allow_loopback_for_tests(&self) {
        self.policy.allow_loopback.store(true, Ordering::Relaxed);
    }

    /// GET `url`, following up to [`MAX_REDIRECTS`] checked redirects, reading at most
    /// `max_body` bytes, all within `timeout`.
    pub async fn get(&self, url: Url, accept: &str, max_body: usize, timeout: Duration) -> Result<Fetched, FetchError> {
        tokio::time::timeout(timeout, self.get_inner(url, accept, max_body))
            .await
            .unwrap_or(Err(FetchError::Network))
    }

    async fn get_inner(&self, mut url: Url, accept: &str, max_body: usize) -> Result<Fetched, FetchError> {
        let mut hops = 0;
        loop {
            self.policy.check_url(&url)?;
            let resp = self
                .client
                .request(Method::GET, url.clone())
                .header(reqwest::header::ACCEPT, accept)
                .send()
                .await
                .map_err(map_err)?;
            let status = resp.status();
            if status.is_redirection() {
                hops += 1;
                if hops > MAX_REDIRECTS {
                    return Err(FetchError::TooManyRedirects);
                }
                let next = resp
                    .headers()
                    .get(LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .and_then(|loc| url.join(loc).ok())
                    .ok_or(FetchError::TooManyRedirects)?;
                url = next;
                continue;
            }
            let headers = resp.headers().clone();
            if resp.content_length().is_some_and(|n| n > max_body as u64) {
                return Err(FetchError::TooLarge);
            }
            let body = read_capped(resp, max_body).await?;
            return Ok(Fetched { url, status, headers, body });
        }
    }

    /// POST `body` to `url` with `headers`, no redirects followed. Returns the status and the
    /// first 4 KiB of the response body.
    pub async fn post(
        &self,
        url: Url,
        headers: HeaderMap,
        body: Vec<u8>,
        timeout: Duration,
    ) -> Result<(StatusCode, Bytes), FetchError> {
        self.policy.check_url(&url)?;
        let fut = async {
            let resp = self.client.post(url).headers(headers).body(body).send().await.map_err(map_err)?;
            let status = resp.status();
            let body = read_capped(resp, 4096).await.unwrap_or_default();
            Ok((status, body))
        };
        tokio::time::timeout(timeout, fut).await.unwrap_or(Err(FetchError::Network))
    }
}

fn map_err(e: reqwest::Error) -> FetchError {
    let mut src: Option<&dyn std::error::Error> = Some(&e);
    while let Some(s) = src {
        if s.is::<BlockedHost>() {
            return FetchError::Blocked;
        }
        src = s.source();
    }
    FetchError::Network
}

async fn read_capped(resp: reqwest::Response, max: usize) -> Result<Bytes, FetchError> {
    let mut out = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| FetchError::Network)?;
        if out.len() + chunk.len() > max {
            return Err(FetchError::TooLarge);
        }
        out.extend_from_slice(&chunk);
    }
    Ok(Bytes::from(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn blocked_ranges() {
        for s in [
            "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.255", "127.0.0.1",
            "127.1.2.3", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.168.1.1", "198.18.0.1",
            "198.19.255.255", "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255", "::", "::1",
            "fc00::1", "fd12:3456::1", "fe80::1", "febf::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
            "::ffff:169.254.169.254", "::ffff:192.168.0.1", "::127.0.0.1", "::10.0.0.1", "64:ff9b::a9fe:a9fe",
            "2002:7f00:1::", "2002:a00:1::",
        ] {
            assert!(!is_public_ip(ip(s)), "{s} must be blocked");
        }
    }

    #[test]
    fn public_ranges() {
        for s in [
            "1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1",
            "169.253.0.1", "198.17.255.255", "198.20.0.1", "223.255.255.255", "93.184.216.34",
            "2606:4700:4700::1111", "2a00:1450:4007:80e::200e", "::ffff:8.8.8.8", "2002:808:808::",
        ] {
            assert!(is_public_ip(ip(s)), "{s} must be allowed");
        }
    }

    #[test]
    fn url_checks() {
        let p = Policy::default();
        let ok = |s: &str| p.check_url(&Url::parse(s).unwrap());
        assert_eq!(ok("https://example.org/a"), Ok(()));
        assert_eq!(ok("http://example.org:80/"), Ok(()));
        assert_eq!(ok("ftp://example.org/"), Err(FetchError::BadUrl));
        assert_eq!(ok("file:///etc/passwd"), Err(FetchError::BadUrl));
        assert_eq!(ok("https://example.org:8443/"), Err(FetchError::BadUrl));
        assert_eq!(ok("http://user:pw@example.org/"), Err(FetchError::BadUrl));
        assert_eq!(ok("http://127.0.0.1/"), Err(FetchError::Blocked));
        assert_eq!(ok("http://2130706433/"), Err(FetchError::Blocked));
        assert_eq!(ok("http://0x7f.1/"), Err(FetchError::Blocked));
        assert_eq!(ok("http://[::1]/"), Err(FetchError::Blocked));
        assert_eq!(ok("http://[::ffff:7f00:1]/"), Err(FetchError::Blocked));
        assert_eq!(ok("http://169.254.169.254/latest/meta-data/"), Err(FetchError::Blocked));
        assert_eq!(ok("http://[fd00::1]/"), Err(FetchError::Blocked));
    }

    #[tokio::test]
    async fn hostname_resolving_to_loopback_is_blocked() {
        let c = GuardedClient::new("test");
        let r = c.get(Url::parse("http://localhost/").unwrap(), "*/*", 1024, Duration::from_secs(5)).await;
        assert_eq!(r.err(), Some(FetchError::Blocked));
    }

    /// A local server that redirects; the test client may reach 127.0.0.1 but nothing else
    /// private, so a redirect to a private address must be refused before any connect.
    #[tokio::test]
    async fn redirects_are_checked_again() {
        use axum::Router;
        use axum::response::Redirect;
        use axum::routing::get;

        let app = Router::new()
            .route("/to-private", get(|| async { Redirect::temporary("http://10.0.0.1/") }))
            .route("/to-metadata", get(|| async { Redirect::temporary("http://169.254.169.254/latest/") }))
            .route("/to-mapped", get(|| async { Redirect::temporary("http://[::ffff:a00:1]/") }))
            .route("/to-ftp", get(|| async { Redirect::temporary("ftp://example.org/") }))
            .route("/loop", get(|| async { Redirect::temporary("/loop") }))
            .route("/hop", get(|| async { Redirect::temporary("/ok") }))
            .route("/ok", get(|| async { "fine" }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let c = GuardedClient::new("test");
        c.allow_loopback_for_tests();
        let get = |p: &str| {
            let u = Url::parse(&format!("http://{addr}{p}")).unwrap();
            c.get(u, "*/*", 1024, Duration::from_secs(5))
        };
        assert_eq!(get("/to-private").await.err(), Some(FetchError::Blocked));
        assert_eq!(get("/to-metadata").await.err(), Some(FetchError::Blocked));
        assert_eq!(get("/to-mapped").await.err(), Some(FetchError::Blocked));
        assert_eq!(get("/to-ftp").await.err(), Some(FetchError::BadUrl));
        assert_eq!(get("/loop").await.err(), Some(FetchError::TooManyRedirects));
        let ok = get("/hop").await.unwrap();
        assert_eq!(ok.body.as_ref(), b"fine");
        assert_eq!(ok.url.path(), "/ok");
        // Body cap.
        let u = Url::parse(&format!("http://{addr}/ok")).unwrap();
        assert_eq!(c.get(u, "*/*", 2, Duration::from_secs(5)).await.err(), Some(FetchError::TooLarge));
    }
}
