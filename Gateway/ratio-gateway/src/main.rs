//! ratio-gateway — the HTTP/SSE surface in front of PIE.
//!
//! Runs as a supervised sibling process (decided 2026-08-01): the helper owns
//! its lifecycle and publishes its port. See doc/chat-refactor.md.

mod chat;
mod engine;
mod routes;

use anyhow::{Result, bail};
use clap::Parser;
use engine::Engine;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::time::Duration;

#[derive(Parser, Debug)]
#[command(about = "HTTP/SSE gateway for the PIE engine")]
struct Args {
    #[arg(long, default_value = "127.0.0.1:8100")]
    listen: String,

    /// Attach mode (production): an engine someone else owns.
    #[arg(long, requires = "pie_token")]
    pie_url: Option<String>,
    #[arg(long, requires = "pie_url")]
    pie_token: Option<String>,

    /// Spawn mode (dev): bring up our own engine.
    #[arg(long)]
    spawn_engine: bool,
    #[arg(long)]
    pie_bin: Option<PathBuf>,
    #[arg(long)]
    pie_config: Option<PathBuf>,
    #[arg(long, default_value = "/tmp/ratio-gateway-pie-home")]
    pie_home: PathBuf,

    #[arg(long)]
    inferlet_wasm: PathBuf,
    #[arg(long)]
    inferlet_manifest: PathBuf,
    #[arg(long, default_value = "echo@0.1.0")]
    inferlet_id: String,
    /// Program id for POST /v1/chat/completions.
    #[arg(long, default_value = "chat@0.1.0")]
    chat_inferlet_id: String,
    /// Extra wasm to install at boot (the chat inferlet).
    #[arg(long)]
    chat_wasm: Option<PathBuf>,
    #[arg(long)]
    chat_manifest: Option<PathBuf>,
    /// Serve this single model id from /v1/models instead of querying pie.
    #[arg(long)]
    model: Option<String>,

    #[arg(long, default_value_t = 30)]
    first_event_timeout_s: u64,
    #[arg(long, default_value_t = 250)]
    cancel_grace_ms: u64,

    /// Write the bound port here so a supervisor can discover it.
    #[arg(long)]
    port_file: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ratio_gateway=info".into()),
        )
        .init();

    let args = Args::parse();

    let engine = match (&args.pie_url, &args.pie_token, args.spawn_engine) {
        (Some(url), Some(tok), false) => {
            tracing::info!(%url, "attaching to engine");
            Engine::attach(url.clone(), tok.clone())
        }
        (None, None, true) => {
            let (Some(bin), Some(cfg)) = (&args.pie_bin, &args.pie_config) else {
                bail!("--spawn-engine requires --pie-bin and --pie-config");
            };
            tracing::info!(bin = %bin.display(), "spawning engine");
            Engine::spawn(bin, cfg, &args.pie_home).await?
        }
        _ => bail!("provide either --pie-url/--pie-token (attach) or --spawn-engine (dev)"),
    };
    tracing::info!(url = %engine.url, "engine ready");

    // Install once at boot on the control connection (§8.4).
    let control = engine.control_client().await?;
    engine::install(&control, &args.inferlet_wasm, &args.inferlet_manifest).await?;
    tracing::info!(inferlet = %args.inferlet_id, "installed");
    if let (Some(w), Some(m)) = (&args.chat_wasm, &args.chat_manifest) {
        engine::install(&control, w, m).await?;
        tracing::info!(inferlet = %args.chat_inferlet_id, "installed");
    }

    let state = Arc::new(routes::AppState {
        engine,
        inferlet: args.inferlet_id.clone(),
        chat_inferlet: args.chat_inferlet_id.clone(),
        model_override: args.model.clone(),
        first_event_timeout: Duration::from_secs(args.first_event_timeout_s),
        cancel_grace: Duration::from_millis(args.cancel_grace_ms),
    });

    let listener = tokio::net::TcpListener::bind(&args.listen).await?;
    let bound = listener.local_addr()?;
    if let Some(pf) = &args.port_file {
        tokio::fs::write(pf, bound.port().to_string()).await.ok();
    }
    tracing::info!(%bound, "ratio-gateway listening");
    println!("ratio-gateway listening on http://{bound}");

    axum::serve(listener, routes::router(state)).await?;
    Ok(())
}
