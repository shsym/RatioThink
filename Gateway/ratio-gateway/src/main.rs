//! ratio-gateway — the HTTP/SSE surface in front of PIE.
//!
//! Runs as a supervised sibling process (decided 2026-08-01): the helper owns
//! its lifecycle and publishes its port. See doc/chat-refactor.md.

mod chat;
mod engine;
mod registry;
mod routes;
mod tree;

use anyhow::{Result, bail};
use clap::Parser;
use engine::Engine;
use registry::Registry;
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

    /// Directory of `{name}.wasm` + `{name}.Pie.toml` pairs. Adding an inferlet
    /// that speaks an already-supported protocol class means dropping two files
    /// here and reloading — no gateway rebuild.
    ///
    /// TRUSTED (plan §3, hole 3): pie authorizes snapshots by
    /// `(username, name)` with no program in the key, so an inferlet here can
    /// read or delete any snapshot regardless of what its manifest declares.
    /// This is not a sandbox for untrusted third-party code.
    #[arg(long)]
    inferlet_dir: PathBuf,
    /// Bearer token for `POST /v1/admin/reload`. Reload is disabled unless set:
    /// the gateway can be exposed beyond loopback, and an unauthenticated
    /// reload lets anyone swap in whatever is on disk.
    #[arg(long, env = "RATIO_ADMIN_TOKEN")]
    admin_token: Option<String>,
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

    // Scan before serving: a malformed manifest must fail startup loudly rather
    // than surface as a 404 on the one route that happened to be broken.
    let reg = Arc::new(Registry::scan(&args.inferlet_dir)?);
    for e in reg.entries() {
        tracing::info!(
            route = %e.route, program = %e.program, protocol = %e.protocol.as_str(),
            digest = %e.digest, preload = e.preload, aliases = ?e.aliases,
            "registered"
        );
    }
    if args.admin_token.is_none() {
        tracing::warn!("no --admin-token: POST /v1/admin/reload will return 404");
    }

    let state = Arc::new(routes::AppState {
        engine,
        registry: std::sync::RwLock::new(Arc::clone(&reg)),
        installed: registry::Installed::default(),
        install_lock: tokio::sync::Mutex::new(()),
        inferlet_dir: args.inferlet_dir.clone(),
        admin_token: args.admin_token.clone(),
        model_override: args.model.clone(),
        first_event_timeout: Duration::from_secs(args.first_event_timeout_s),
        cancel_grace: Duration::from_millis(args.cancel_grace_ms),
    });

    // Eager install for `preload = true`; everything else installs on first use,
    // so a rarely-used inferlet costs nothing at boot.
    for e in reg.entries().filter(|e| e.preload) {
        state.ensure_installed(e).await?;
    }

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
