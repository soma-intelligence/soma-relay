use std::net::SocketAddr;
use std::path::PathBuf;

use clap::{Parser, Subcommand};
use relay_bot::inbox::Inbox;
use relay_bot::{Bot, Settings, api, engine, inbox_path, load_or_create_token, node, token_path};

#[derive(Parser)]
#[command(name = "relay-bot", version, about = "Soma Relay bot runtime")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run a bot: connect to a node and expose the local REST API.
    Serve {
        /// Node base URL, for example https://relay.example.org.
        #[arg(long, env = "RELAY_BOT_NODE")]
        node: url::Url,
        /// Display name of the bot (used when the identity is created).
        #[arg(long, env = "RELAY_BOT_NAME")]
        name: String,
        /// Address of the local REST API.
        #[arg(long, env = "RELAY_BOT_LISTEN", default_value = "127.0.0.1:8787")]
        listen: SocketAddr,
        /// URL that receives a JSON POST for each incoming message.
        #[arg(long, env = "RELAY_BOT_WEBHOOK")]
        webhook: Option<url::Url>,
        /// Engine state file (identity, contacts, sessions). Keep it private.
        #[arg(long, env = "RELAY_BOT_STATE", default_value = "./bot-state.bin")]
        state: PathBuf,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("RELAY_LOG").unwrap_or_else(|_| "relay_bot=info".into()),
        )
        .init();

    let Cmd::Serve { node: node_url, name, listen, webhook, state } = Cli::parse().cmd;

    let (engine, created) = engine::load_or_create(&state, &name)?;
    let (token, new_token) = load_or_create_token(&state)?;
    let settings = Settings { node_url, state_path: state.clone(), webhook, token: token.clone() };
    let (bot, outbox) = Bot::new(engine, settings, Inbox::open(inbox_path(&state)));
    if created {
        bot.save();
    }

    println!("relay-bot \"{}\"", bot.engine.display_name());
    println!("  fingerprint  {}", bot.engine.fingerprint_hex());
    println!("  mailbox      {}", bot.engine.mailbox_hex());
    println!("  link         {}", bot.my_link());
    if new_token {
        println!("  API token    {token}");
        println!("               (saved in {}, shown only once)", token_path(&state).display());
    } else {
        println!("  API token    in {}", token_path(&state).display());
    }
    println!("  API          http://{listen}  (card: /v1/card, QR: /v1/card.png)");

    tokio::spawn(node::run(bot.clone(), outbox));
    let listener = tokio::net::TcpListener::bind(listen).await?;
    axum::serve(listener, api::router(bot))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
