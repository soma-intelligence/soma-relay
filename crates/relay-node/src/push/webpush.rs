//! Web Push: VAPID (RFC 8292) and aes128gcm payload encryption (RFC 8291).

use std::path::Path;
use std::time::Duration;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use hkdf::Hkdf;
use p256::ecdsa::SigningKey;
use p256::elliptic_curve::rand_core::{OsRng, RngCore};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::pkcs8::{DecodePrivateKey, EncodePrivateKey, LineEnding};
use p256::{PublicKey, SecretKey};
use reqwest::Url;
use reqwest::header::{HeaderMap, HeaderValue};
use serde_json::{Value, json};
use sha2::Sha256;

use super::{Outcome, es256_jwt, unix_now};
use crate::netguard::{FetchError, GuardedClient};
use crate::util::{b64, unb64};

/// Contact in the VAPID `sub` claim.
pub const VAPID_SUBJECT: &str = "mailto:opensource@somalabs.me";
/// The wake payload. It carries nothing about the message.
pub const WAKE_PAYLOAD: &[u8] = br#"{"t":"wake"}"#;
/// Push service TTL: one day.
pub const TTL_SECS: u32 = 86_400;
/// Record size written in the aes128gcm header.
const RECORD_SIZE: u32 = 4096;
const VAPID_FILE: &str = "vapid.pem";

/// The node's VAPID key pair.
pub struct Vapid {
    key: SigningKey,
    public_b64: String,
}

impl Vapid {
    /// Loads `<data_dir>/vapid.pem`, or generates and saves a new P-256 key on first start.
    pub fn load_or_create(data_dir: &Path) -> anyhow::Result<Self> {
        let path = data_dir.join(VAPID_FILE);
        let secret = match std::fs::read_to_string(&path) {
            Ok(pem) => SecretKey::from_pkcs8_pem(&pem).map_err(|e| anyhow::anyhow!("{}: {e}", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let secret = SecretKey::random(&mut OsRng);
                let pem = secret.to_pkcs8_pem(LineEnding::LF).map_err(|e| anyhow::anyhow!("vapid encode: {e}"))?;
                write_private(&path, pem.as_bytes())?;
                tracing::info!("generated a new VAPID key");
                secret
            }
            Err(e) => return Err(e.into()),
        };
        Ok(Self::from_secret(secret))
    }

    pub fn from_secret(secret: SecretKey) -> Self {
        let public_b64 = b64(secret.public_key().to_encoded_point(false).as_bytes());
        Self { key: SigningKey::from(secret), public_b64 }
    }

    /// Uncompressed public key (65 bytes), base64url without padding.
    pub fn public_b64(&self) -> &str {
        &self.public_b64
    }

    /// The `Authorization` header value for a push to `endpoint`.
    pub fn authorization(&self, endpoint: &Url) -> String {
        let claims = json!({
            "aud": endpoint.origin().ascii_serialization(),
            "exp": unix_now() + 12 * 3600,
            "sub": VAPID_SUBJECT,
        });
        let jwt = es256_jwt(&json!({"typ": "JWT", "alg": "ES256"}), &claims, &self.key);
        format!("vapid t={jwt}, k={}", self.public_b64)
    }

    /// Sends the wake payload to `sub`.
    pub async fn send(&self, net: &GuardedClient, sub: &Subscription) -> Outcome {
        let mut salt = [0u8; 16];
        OsRng.fill_bytes(&mut salt);
        let eph = SecretKey::random(&mut OsRng);
        let Some(body) = encrypt(WAKE_PAYLOAD, &sub.p256dh, &sub.auth, &eph, &salt) else {
            return Outcome::Remove;
        };
        let mut h = HeaderMap::new();
        h.insert("content-encoding", HeaderValue::from_static("aes128gcm"));
        h.insert("content-type", HeaderValue::from_static("application/octet-stream"));
        h.insert("ttl", HeaderValue::from(TTL_SECS));
        h.insert("urgency", HeaderValue::from_static("high"));
        match HeaderValue::from_str(&self.authorization(&sub.endpoint)) {
            Ok(v) => h.insert("authorization", v),
            Err(_) => return Outcome::Failed,
        };
        match net.post(sub.endpoint.clone(), h, body, Duration::from_secs(10)).await {
            Ok((status, _)) if status.is_success() => Outcome::Sent,
            Ok((status, _)) if status.as_u16() == 404 || status.as_u16() == 410 => Outcome::Remove,
            Ok((status, _)) => {
                tracing::warn!(status = status.as_u16(), "web push refused");
                Outcome::Failed
            }
            Err(FetchError::Blocked) | Err(FetchError::BadUrl) => Outcome::Remove,
            Err(_) => Outcome::Failed,
        }
    }
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(path)?;
    f.write_all(bytes)?;
    f.sync_all()
}

/// A browser push subscription (`PushSubscription.toJSON()`).
#[derive(Debug, Clone)]
pub struct Subscription {
    pub endpoint: Url,
    /// Uncompressed P-256 public key of the user agent (65 bytes).
    pub p256dh: Vec<u8>,
    /// Auth secret (16 bytes).
    pub auth: Vec<u8>,
}

impl Subscription {
    /// Parses and validates a subscription from a client. The endpoint must be an https URL
    /// on a public address (port 443 or 80).
    pub fn from_json(v: &Value, net: &GuardedClient) -> Option<Self> {
        let endpoint = v.get("endpoint")?.as_str()?;
        if endpoint.len() > 2048 {
            return None;
        }
        let endpoint = Url::parse(endpoint).ok()?;
        if net.policy().check_url(&endpoint).is_err() {
            return None;
        }
        if endpoint.scheme() != "https" && !net.policy().loopback_ok() {
            return None;
        }
        let keys = v.get("keys")?;
        let p256dh = unb64(keys.get("p256dh")?.as_str()?)?;
        let auth = unb64(keys.get("auth")?.as_str()?)?;
        if p256dh.len() != 65 || PublicKey::from_sec1_bytes(&p256dh).is_err() || auth.len() != 16 {
            return None;
        }
        Some(Self { endpoint, p256dh, auth })
    }

    /// Parses a subscription stored by [`Subscription::to_json`], without the address check
    /// (the sender checks the address again when it connects).
    pub fn from_stored(s: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(s).ok()?;
        let endpoint = Url::parse(v.get("endpoint")?.as_str()?).ok()?;
        let keys = v.get("keys")?;
        let p256dh = unb64(keys.get("p256dh")?.as_str()?)?;
        let auth = unb64(keys.get("auth")?.as_str()?)?;
        Some(Self { endpoint, p256dh, auth })
    }

    pub fn to_json(&self) -> String {
        json!({"endpoint": self.endpoint.as_str(), "keys": {"p256dh": b64(&self.p256dh), "auth": b64(&self.auth)}})
            .to_string()
    }
}

fn hkdf_expand(prk: &Hkdf<Sha256>, info: &[u8], out: &mut [u8]) {
    prk.expand(info, out).expect("output length is small");
}

/// Derives the content encryption key and nonce (RFC 8291 section 3.4).
fn derive(ecdh: &[u8], auth: &[u8], ua_public: &[u8], as_public: &[u8], salt: &[u8]) -> ([u8; 16], [u8; 12]) {
    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(ua_public);
    key_info.extend_from_slice(as_public);
    let mut ikm = [0u8; 32];
    hkdf_expand(&Hkdf::<Sha256>::new(Some(auth), ecdh), &key_info, &mut ikm);
    let prk = Hkdf::<Sha256>::new(Some(salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    hkdf_expand(&prk, b"Content-Encoding: aes128gcm\0", &mut cek);
    hkdf_expand(&prk, b"Content-Encoding: nonce\0", &mut nonce);
    (cek, nonce)
}

/// Encrypts `plaintext` for a subscription as one aes128gcm record (RFC 8291 + RFC 8188).
/// `as_secret` is the ephemeral application server key, `salt` 16 random bytes.
pub fn encrypt(plaintext: &[u8], ua_public: &[u8], auth: &[u8], as_secret: &SecretKey, salt: &[u8; 16]) -> Option<Vec<u8>> {
    let ua = PublicKey::from_sec1_bytes(ua_public).ok()?;
    let as_public = as_secret.public_key().to_encoded_point(false);
    let shared = p256::ecdh::diffie_hellman(as_secret.to_nonzero_scalar(), ua.as_affine());
    let (cek, nonce) = derive(shared.raw_secret_bytes(), auth, ua_public, as_public.as_bytes(), salt);
    let mut record = plaintext.to_vec();
    record.push(2); // last-record delimiter, no padding
    let ct = Aes128Gcm::new(&cek.into()).encrypt(Nonce::from_slice(&nonce), record.as_slice()).ok()?;
    let mut out = Vec::with_capacity(16 + 4 + 1 + 65 + ct.len());
    out.extend_from_slice(salt);
    out.extend_from_slice(&RECORD_SIZE.to_be_bytes());
    out.push(as_public.as_bytes().len() as u8);
    out.extend_from_slice(as_public.as_bytes());
    out.extend_from_slice(&ct);
    Some(out)
}

/// Decrypts an aes128gcm body with the user agent's private key (what a browser does).
/// Used by tests.
#[doc(hidden)]
pub fn decrypt(body: &[u8], ua_secret: &SecretKey, auth: &[u8]) -> Option<Vec<u8>> {
    let salt = body.get(..16)?;
    let idlen = *body.get(20)? as usize;
    let as_public = body.get(21..21 + idlen)?;
    let ct = body.get(21 + idlen..)?;
    let as_key = PublicKey::from_sec1_bytes(as_public).ok()?;
    let ua_public = ua_secret.public_key().to_encoded_point(false);
    let shared = p256::ecdh::diffie_hellman(ua_secret.to_nonzero_scalar(), as_key.as_affine());
    let (cek, nonce) = derive(shared.raw_secret_bytes(), auth, ua_public.as_bytes(), as_public, salt);
    let mut pt = Aes128Gcm::new(&cek.into()).decrypt(Nonce::from_slice(&nonce), ct).ok()?;
    while pt.last() == Some(&0) {
        pt.pop();
    }
    (pt.pop() == Some(2)).then_some(pt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::decode_jwt;

    fn d(s: &str) -> Vec<u8> {
        unb64(s).unwrap()
    }

    /// RFC 8291 Appendix A.
    #[test]
    fn rfc8291_test_vector() {
        let plaintext = d("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24");
        let as_secret = SecretKey::from_slice(&d("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")).unwrap();
        assert_eq!(
            b64(as_secret.public_key().to_encoded_point(false).as_bytes()),
            "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        );
        let ua_secret = SecretKey::from_slice(&d("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")).unwrap();
        let ua_public = d("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
        assert_eq!(ua_secret.public_key().to_encoded_point(false).as_bytes(), ua_public.as_slice());
        let salt: [u8; 16] = d("DGv6ra1nlYgDCS1FRnbzlw").try_into().unwrap();
        let auth = d("BTBZMqHH6r4Tts7J_aSIgg");
        let body = encrypt(&plaintext, &ua_public, &auth, &as_secret, &salt).unwrap();
        assert_eq!(
            b64(&body),
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        );
        assert_eq!(decrypt(&body, &ua_secret, &auth).unwrap(), plaintext);
    }

    #[test]
    fn vapid_key_persists_and_jwt_shape() {
        let dir = tempfile::tempdir().unwrap();
        let a = Vapid::load_or_create(dir.path()).unwrap();
        let b = Vapid::load_or_create(dir.path()).unwrap();
        assert_eq!(a.public_b64(), b.public_b64());
        let pk = d(a.public_b64());
        assert_eq!((pk.len(), pk[0]), (65, 4));

        let endpoint = Url::parse("https://fcm.googleapis.com/fcm/send/abc?x=1").unwrap();
        let auth = a.authorization(&endpoint);
        let (t, k) = auth.strip_prefix("vapid t=").unwrap().split_once(", k=").unwrap();
        assert_eq!(k, a.public_b64());
        let (h, c, s) = decode_jwt(t).unwrap();
        assert_eq!((h["typ"].as_str(), h["alg"].as_str()), (Some("JWT"), Some("ES256")));
        assert_eq!(c["aud"], "https://fcm.googleapis.com");
        assert_eq!(c["sub"], VAPID_SUBJECT);
        let exp = c["exp"].as_u64().unwrap();
        assert!(exp > unix_now() && exp <= unix_now() + 24 * 3600);
        assert_eq!(s.len(), 64);
    }
}
