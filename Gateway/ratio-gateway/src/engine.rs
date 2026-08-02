//! PIE engine bootstrap and connection policy (doc/chat-refactor.md §8.2, §8.4).
//!
//! Two modes: attach to an engine someone else owns (production — the helper
//! owns the lifecycle), or spawn one (dev). Spawning parses the handshake off
//! **stderr**, not stdout, and requires `--debug` for the token line.

use anyhow::{Context, Result, anyhow};
use pie_client::client::Client;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::time::{Duration, timeout};

pub struct Engine {
    pub url: String,
    pub token: String,
    /// Kept alive for dev-spawn mode; dropping it kills the engine.
    _child: Option<Child>,
}

/// `pie serve` prints both on stderr (server/src/serve.rs:410-415,159).
fn parse_addr(line: &str) -> Option<String> {
    let re = regex::Regex::new(r"pie-server serving on (\S+:\d+)").ok()?;
    re.captures(line)?.get(1).map(|m| m.as_str().to_string())
}

fn parse_token(line: &str) -> Option<String> {
    let re = regex::Regex::new(r"internal token: (\S+)").ok()?;
    re.captures(line)?.get(1).map(|m| m.as_str().to_string())
}

impl Engine {
    pub fn attach(url: String, token: String) -> Self {
        Self { url, token, _child: None }
    }

    /// Dev mode. `--debug` is mandatory: without it `server.verbose` stays
    /// false and the `internal token:` line is never printed, so the handshake
    /// hangs with no diagnostic (serve_cmd.rs:66-67).
    pub async fn spawn(pie_bin: &Path, config: &Path, pie_home: &Path) -> Result<Self> {
        tokio::fs::create_dir_all(pie_home).await.ok();
        let mut child = Command::new(pie_bin)
            .args(["serve", "--config"])
            .arg(config)
            .args(["--no-auth", "--debug"])
            .env("PIE_HOME", pie_home)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("failed to spawn {}", pie_bin.display()))?;

        let stderr = child.stderr.take().ok_or_else(|| anyhow!("no stderr pipe"))?;
        let mut lines = BufReader::new(stderr).lines();
        let (mut addr, mut token) = (None, None);

        let handshake = timeout(Duration::from_secs(180), async {
            while addr.is_none() || token.is_none() {
                let Some(line) = lines.next_line().await? else {
                    return Err(anyhow!("pie exited during handshake"));
                };
                tracing::debug!(target: "pie", "{line}");
                if addr.is_none() {
                    addr = parse_addr(&line);
                }
                if token.is_none() {
                    token = parse_token(&line);
                }
            }
            Ok::<_, anyhow::Error>(())
        })
        .await;
        handshake.map_err(|_| anyhow!("timed out parsing pie handshake"))??;

        // Keep draining stderr so the pipe buffer cannot fill and wedge pie.
        tokio::spawn(async move {
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::debug!(target: "pie", "{line}");
            }
        });

        Ok(Self {
            url: format!("ws://{}", addr.unwrap()),
            token: token.unwrap(),
            _child: Some(child),
        })
    }

    /// One long-lived control client for boot-time work only. It must never
    /// carry process events — those go on per-request connections (§8.2).
    pub async fn control_client(&self) -> Result<Client> {
        let c = Client::connect(&self.url).await.context("control connect")?;
        c.auth_by_token(&self.token).await.context("control auth")?;
        Ok(c)
    }

    /// A fresh connection per request. Sidesteps the head-of-line blocking in
    /// the shared WS reader (§2.3) by giving each stream its own reader task.
    pub async fn request_client(&self) -> Result<Client> {
        let c = Client::connect(&self.url).await?;
        c.auth_by_token(&self.token).await?;
        Ok(c)
    }
}

/// Install once at boot — `program::add` is global (handler.rs:409) and each
/// session caches `installed_programs` (handler.rs:465-473).
pub async fn install(client: &Client, wasm: &PathBuf, manifest: &PathBuf) -> Result<()> {
    client
        .add_program(wasm.as_path(), manifest.as_path(), true)
        .await
        .with_context(|| format!("add_program failed for {}", wasm.display()))
}
