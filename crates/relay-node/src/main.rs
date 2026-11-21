use clap::Parser;
use std::sync::Arc;

use relay_node::verifier::CoreCardVerifier;
use relay_node::{Config, NodeState, serve, shutdown_signal};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("RELAY_LOG").unwrap_or_else(|_| "relay_node=info".into()),
        )
        .init();

    let config = Config::parse();
    let listener = tokio::net::TcpListener::bind(config.listen).await?;
    tracing::info!(
        addr = %listener.local_addr()?,
        data = %config.data_dir.display(),
        web = %config.web_dir.display(),
        public_url = config.public_url.as_deref().unwrap_or("-"),
        "relay-node listening"
    );
    let state = NodeState::with_verifier(config, Arc::new(CoreCardVerifier))?;
    serve(listener, state, shutdown_signal()).await
}
