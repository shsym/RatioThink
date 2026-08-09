//! HTTP/SSE gateway for PIE-hosted inferlets.

mod chat;
mod engine;
mod registry;
mod routes;
mod tree;

use anyhow::{Result, bail};
use clap::Parser;
use engine::Engine;
use registry::Registry;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::AsyncReadExt;
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

    /// Trusted directory of `{name}.wasm` + `{name}.Pie.toml` pairs.
    #[arg(long)]
    inferlet_dir: PathBuf,
    /// Bearer token for `POST /v1/admin/reload`; unset disables reload.
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

    /// Exit when stdin closes. The production helper uses this as a
    /// kernel-enforced lifetime link, including when the helper is SIGKILLed.
    #[arg(long)]
    exit_on_stdin_eof: bool,
}

struct PortFileGuard(Option<PathBuf>);

impl Drop for PortFileGuard {
    fn drop(&mut self) {
        if let Some(path) = &self.0 {
            if let Err(error) = std::fs::remove_file(path)
                && error.kind() != std::io::ErrorKind::NotFound
            {
                tracing::warn!(path = %path.display(), %error, "failed to remove port file");
            }
        }
    }
}

async fn stdin_eof() {
    let mut stdin = tokio::io::stdin();
    let mut buffer = [0_u8; 1];
    loop {
        match stdin.read(&mut buffer).await {
            Ok(0) => return,
            Ok(_) => {}
            Err(error) => {
                tracing::warn!(%error, "stdin lifetime link failed");
                return;
            }
        }
    }
}

fn remove_stale_port_file(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
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

    for e in reg.entries().filter(|e| e.preload) {
        state.ensure_installed(e).await?;
    }

    let listener = tokio::net::TcpListener::bind(&args.listen).await?;
    let bound = listener.local_addr()?;
    let _port_file_guard = PortFileGuard(args.port_file.clone());
    if let Some(pf) = &args.port_file {
        remove_stale_port_file(pf)?;
        tokio::fs::write(pf, bound.port().to_string()).await?;
    }
    tracing::info!(%bound, "ratio-gateway listening");
    println!("ratio-gateway listening on http://{bound}");

    let server = axum::serve(listener, routes::router(state));
    if args.exit_on_stdin_eof {
        server.with_graceful_shutdown(stdin_eof()).await?;
    } else {
        server.await?;
    }
    Ok(())
}
