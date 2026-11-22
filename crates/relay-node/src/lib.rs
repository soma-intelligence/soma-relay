//! Soma Relay node: an optional, self-hostable server that gives clients a store-and-forward
//! mailbox over WebSocket, a handle directory, an encrypted blob store, an ICE server list
//! and the static web client. It never sees plaintext: envelopes, cards and blobs are opaque.
//!
//! The wire protocol is described in `docs/node-protocol.md`.

pub mod http;
pub mod netguard;
pub mod preview;
pub mod push;
pub mod ratelimit;
pub mod store;
pub mod turn;
pub mod util;
pub mod vault;
pub mod verifier;
pub mod ws;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use axum::Router;
use clap::Parser;
use tokio::sync::{Mutex, mpsc, watch};

use crate::netguard::GuardedClient;
use crate::preview::Previewer;
use crate::push::Notifier;
use crate::push::apns::Apns;
use crate::push::webpush::Vapid;
use crate::ratelimit::IpLimiter;
use crate::store::Store;
use crate::turn::TurnConfig;
use crate::verifier::{CardVerifier, PermissiveVerifier};

/// How long envelopes and blobs are kept: 14 days.
pub const RETENTION_MS: i64 = 14 * 24 * 3600 * 1000;
/// Per-mailbox queue quota: 50 MiB.
pub const MAILBOX_QUOTA: i64 = 50 * 1024 * 1024;
/// Largest blob: 100 MiB.
pub const MAX_BLOB_BYTES: u64 = 100 * 1024 * 1024;
/// Largest single envelope accepted in a `send` frame: 2 MiB.
pub const MAX_ENVELOPE_BYTES: usize = 2 * 1024 * 1024;
/// Largest WebSocket text frame: 4 MiB (a 2 MiB envelope in base64 plus JSON).
pub const MAX_WS_FRAME: usize = 4 * 1024 * 1024;

const DEFAULT_ICE: &str = r#"[{"urls":["stun:stun.l.google.com:19302","stun:stun1.l.google.com:19302"]},{"urls":["stun:stun.cloudflare.com:3478"]}]"#;

/// Node configuration, from CLI flags or environment variables.
#[derive(Debug, Clone, Parser)]
#[command(name = "relay-node", version, about = "Soma Relay node (mailbox, directory, blobs, web client)")]
pub struct Config {
    /// Address to listen on.
    #[arg(long, env = "RELAY_LISTEN", default_value = "0.0.0.0:8080")]
    pub listen: SocketAddr,

    /// Directory for the SQLite database and blobs.
    #[arg(long, env = "RELAY_DATA_DIR", default_value = "./relay-data")]
    pub data_dir: PathBuf,

    /// Public base URL of this node, for example https://relay.example.org.
    #[arg(long, env = "RELAY_PUBLIC_URL")]
    pub public_url: Option<String>,

    /// Directory of the built web client served at `/`.
    #[arg(long, env = "RELAY_WEB_DIR", default_value = "./web/dist")]
    pub web_dir: PathBuf,

    /// ICE servers as JSON (an array of RTCIceServer, or an object with `iceServers`).
    #[arg(long, env = "RELAY_ICE_JSON")]
    pub ice_json: Option<String>,

    /// coturn `static-auth-secret` (TURN REST API). With `--turn-urls`, `/v1/ice` adds a TURN
    /// entry with fresh short-lived credentials on every request.
    #[arg(long, env = "RELAY_TURN_SECRET", hide_env_values = true)]
    pub turn_secret: Option<String>,

    /// TURN URLs, comma separated, for example
    /// `turn:host:3478?transport=udp,turn:host:3478?transport=tcp,turns:host:5349?transport=tcp`.
    #[arg(long, env = "RELAY_TURN_URLS")]
    pub turn_urls: Option<String>,

    /// Lifetime of the TURN credentials, in seconds.
    #[arg(long, env = "RELAY_TURN_TTL", default_value_t = 86400)]
    pub turn_ttl: u64,

    /// Take the client IP from the first `X-Forwarded-For` entry (only behind a trusted proxy).
    #[arg(long, env = "RELAY_TRUST_PROXY", default_value_t = false)]
    pub trust_proxy: bool,

    /// HTTP requests per second allowed per IP (token bucket refill rate). 0 disables.
    #[arg(long, env = "RELAY_RATE_PER_SEC", default_value_t = 20.0)]
    pub rate_per_sec: f64,

    /// HTTP request burst per IP (token bucket size).
    #[arg(long, env = "RELAY_RATE_BURST", default_value_t = 100.0)]
    pub rate_burst: f64,

    /// APNs auth key: the PEM text of the `.p8` file, or a path to it. APNs is off unless
    /// this and the three settings below are all set.
    #[arg(long, env = "RELAY_APNS_KEY_P8", hide_env_values = true)]
    pub apns_key_p8: Option<String>,

    /// APNs key id (10 characters, from the Apple developer account).
    #[arg(long, env = "RELAY_APNS_KEY_ID")]
    pub apns_key_id: Option<String>,

    /// Apple developer team id.
    #[arg(long, env = "RELAY_APNS_TEAM_ID")]
    pub apns_team_id: Option<String>,

    /// APNs topic: the iOS app bundle id.
    #[arg(long, env = "RELAY_APNS_TOPIC")]
    pub apns_topic: Option<String>,

    /// Serve link previews at `/v1/preview`.
    #[arg(long, env = "RELAY_PREVIEW", default_value_t = true, action = clap::ArgAction::Set)]
    pub preview: bool,
}

impl Config {
    /// A config for tests and embedding: everything under `data_dir`, no web dir.
    pub fn for_data_dir(data_dir: PathBuf) -> Self {
        Self {
            listen: "127.0.0.1:0".parse().unwrap(),
            web_dir: data_dir.join("web"),
            data_dir,
            public_url: None,
            ice_json: None,
            turn_secret: None,
            turn_urls: None,
            turn_ttl: 86400,
            trust_proxy: false,
            rate_per_sec: 0.0,
            rate_burst: 100.0,
            apns_key_p8: None,
            apns_key_id: None,
            apns_team_id: None,
            apns_topic: None,
            preview: true,
        }
    }

    fn ice_servers(&self) -> serde_json::Value {
        let raw = self.ice_json.as_deref().unwrap_or(DEFAULT_ICE);
        let parsed: serde_json::Value = match serde_json::from_str(raw) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("RELAY_ICE_JSON is not valid JSON ({e}), using the default STUN list");
                serde_json::from_str(DEFAULT_ICE).unwrap()
            }
        };
        match parsed {
            serde_json::Value::Object(mut o) if o.contains_key("iceServers") => o.remove("iceServers").unwrap(),
            other => other,
        }
    }
}

/// Outbound frame queue of one authenticated connection.
pub(crate) type ConnTx = mpsc::Sender<String>;

/// Live connections per mailbox (several devices or tabs may share one mailbox).
#[derive(Default)]
pub(crate) struct Hub {
    conns: HashMap<[u8; 16], HashMap<u64, ConnTx>>,
}

/// Shared node state.
pub struct NodeState {
    pub config: Config,
    pub store: Store,
    pub verifier: Arc<dyn CardVerifier>,
    pub(crate) hub: Mutex<Hub>,
    pub(crate) next_conn: AtomicU64,
    pub(crate) http_limiter: IpLimiter,
    pub(crate) ice: serde_json::Value,
    pub(crate) turn: Option<TurnConfig>,
    pub(crate) notifier: Notifier,
    pub(crate) net: GuardedClient,
    pub(crate) previewer: Previewer,
    pub(crate) shutdown: watch::Receiver<bool>,
    shutdown_tx: watch::Sender<bool>,
}

impl NodeState {
    /// Opens the data directory and the database, with the permissive card verifier.
    pub fn open(config: Config) -> anyhow::Result<Arc<Self>> {
        Self::with_verifier(config, Arc::new(PermissiveVerifier))
    }

    /// Same as [`NodeState::open`] with a custom [`CardVerifier`].
    pub fn with_verifier(config: Config, verifier: Arc<dyn CardVerifier>) -> anyhow::Result<Arc<Self>> {
        std::fs::create_dir_all(config.data_dir.join("blobs"))?;
        let store = Store::open(&config.data_dir.join("relay.sqlite3"))?;
        let apns = Apns::from_config(
            config.apns_key_p8.as_deref(),
            config.apns_key_id.as_deref(),
            config.apns_team_id.as_deref(),
            config.apns_topic.as_deref(),
        )?;
        tracing::info!(apns = apns.is_some(), "push senders ready");
        if config.turn_secret.is_some() != config.turn_urls.is_some() {
            tracing::warn!("TURN is off: set both RELAY_TURN_SECRET and RELAY_TURN_URLS");
        }
        let notifier = Notifier::new(apns, Vapid::load_or_create(&config.data_dir)?);
        let net = GuardedClient::new(concat!("SomaRelayNode/", env!("CARGO_PKG_VERSION"), " (link preview)"));
        let (shutdown_tx, shutdown) = watch::channel(false);
        Ok(Arc::new(Self {
            notifier,
            net,
            previewer: Previewer::default(),
            ice: config.ice_servers(),
            turn: TurnConfig::new(config.turn_secret.as_deref(), config.turn_urls.as_deref(), config.turn_ttl),
            http_limiter: IpLimiter::new(config.rate_per_sec, config.rate_burst),
            config,
            store,
            verifier,
            hub: Mutex::new(Hub::default()),
            next_conn: AtomicU64::new(1),
            shutdown,
            shutdown_tx,
        }))
    }

    /// The ICE servers handed to a client: the configured list, plus a TURN entry with fresh
    /// credentials when TURN is configured.
    pub(crate) fn ice_servers(&self) -> serde_json::Value {
        let Some(turn) = &self.turn else { return self.ice.clone() };
        let mut list = match &self.ice {
            serde_json::Value::Array(a) => a.clone(),
            serde_json::Value::Null => Vec::new(),
            other => vec![other.clone()],
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        list.push(turn.ice_server(now));
        serde_json::Value::Array(list)
    }

    pub(crate) fn blob_path(&self, sha: &str) -> PathBuf {
        self.config.data_dir.join("blobs").join(sha)
    }

    pub(crate) fn conn_id(&self) -> u64 {
        self.next_conn.fetch_add(1, Ordering::Relaxed)
    }

    /// The VAPID public key (uncompressed P-256, base64url) for Web Push subscriptions.
    pub fn vapid_public_key(&self) -> &str {
        self.notifier.vapid.public_b64()
    }

    /// Tests only: lets link previews and Web Push reach 127.0.0.0/8 on any port over http.
    #[doc(hidden)]
    pub fn allow_loopback_for_tests(&self) {
        self.net.allow_loopback_for_tests();
    }

    /// Tells every WebSocket connection to close.
    pub fn begin_shutdown(&self) {
        let _ = self.shutdown_tx.send(true);
    }

    /// Removes expired envelopes and blobs. Called periodically by [`serve`].
    pub async fn sweep(&self) {
        let now = util::now_ms();
        match self.store.sweep(now) {
            Ok((envs, shas)) => {
                for sha in &shas {
                    let _ = tokio::fs::remove_file(self.blob_path(sha)).await;
                }
                if envs > 0 || !shas.is_empty() {
                    tracing::info!(envelopes = envs, blobs = shas.len(), "expired items removed");
                }
            }
            Err(e) => tracing::error!("sweep failed: {e}"),
        }
        match self.store.sweep_vaults(now - store::VAULT_RETENTION_MS) {
            Ok(0) => {}
            Ok(n) => tracing::info!(vaults = n, "expired vaults removed"),
            Err(e) => tracing::error!("vault sweep failed: {e}"),
        }
        self.http_limiter.prune();
        self.previewer.limiter.prune();
    }
}

/// Builds the full router: API, WebSocket and static web client.
pub fn router(state: Arc<NodeState>) -> Router {
    http::router(state)
}

/// Runs the node on `listener` until `shutdown` resolves, then closes WebSocket connections
/// and drains in-flight requests.
pub async fn serve(
    listener: tokio::net::TcpListener,
    state: Arc<NodeState>,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let sweeper = {
        let state = state.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(600));
            loop {
                tick.tick().await;
                state.sweep().await;
            }
        })
    };
    let app = router(state.clone());
    let st = state.clone();
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async move {
            shutdown.await;
            st.begin_shutdown();
        })
        .await?;
    sweeper.abort();
    Ok(())
}

/// Resolves on Ctrl-C or SIGTERM.
pub async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {},
        _ = term => {},
    }
    tracing::info!("shutting down");
}
