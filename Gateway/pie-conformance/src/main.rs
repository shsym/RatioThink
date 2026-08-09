//! PIE transport conformance.
//!
//! Verifies launch-event delivery under concurrency and bounded cooperative
//! cancellation before authoritative termination.

use anyhow::{Context, Result, anyhow};
use clap::Parser;
// NOTE: pie-client does not re-export at the crate root (lib.rs is just
// `pub mod client; …`), so these come from the `client` module.
use pie_client::client::{Client, Process, ProcessEvent};
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Parser, Debug)]
struct Args {
    /// ws://host:port from pie's stderr handshake banner.
    #[arg(long)]
    url: String,
    /// The `internal token:` line (needs `--debug` on the engine).
    #[arg(long)]
    token: String,
    #[arg(long)]
    wasm: String,
    #[arg(long)]
    manifest: String,
    #[arg(long, default_value = "echo@0.1.0")]
    inferlet: String,
    /// Launch/drain iterations for the loss test.
    #[arg(long, default_value_t = 500)]
    iterations: u32,
    /// Events the inferlet emits before its finish frame.
    #[arg(long, default_value_t = 4)]
    count: u32,
    /// Grace allowed for the guest to emit its own terminal frame after cancel.
    #[arg(long, default_value_t = 1000)]
    grace_ms: u64,
    /// Simultaneous in-flight launches per batch. 1 = sequential.
    #[arg(long, default_value_t = 1)]
    concurrency: u32,
}

/// Drain one process to termination.
async fn drain(proc: &mut Process) -> Result<Vec<String>> {
    let mut msgs = Vec::new();
    loop {
        match tokio::time::timeout(Duration::from_secs(30), proc.recv()).await {
            Err(_) => return Err(anyhow!("timed out waiting for events")),
            Ok(Err(e)) => return Err(anyhow!("recv failed: {e}")),
            Ok(Ok(ev)) => match ev {
                ProcessEvent::Message(s) => msgs.push(s),
                ProcessEvent::Return(_) => break,
                ProcessEvent::Error(e) => return Err(anyhow!("process error: {e}")),
                _ => {}
            },
        }
    }
    Ok(msgs)
}

/// Property A: launch → emit → drain, N times, counting lost events.
async fn test_no_loss(args: &Args, client: &Client) -> Result<bool> {
    let expected = args.count + 1; // count echoes + one finish frame
    let input = serde_json::json!({ "count": args.count, "hold_ms": 0 }).to_string();

    let mut lossy_runs = 0u32;
    let mut lost_events = 0u32;
    let mut worst = expected;
    let started = Instant::now();

    let conc = args.concurrency.max(1);
    let mut done = 0u32;
    while done < args.iterations {
        let batch = conc.min(args.iterations - done);
        // All launches issued before any draining, so the registration window
        // for the later ones overlaps the earlier ones' event traffic.
        let mut procs = Vec::with_capacity(batch as usize);
        for _ in 0..batch {
            procs.push(
                client
                    .launch_process(args.inferlet.clone(), input.clone(), true, None)
                    .await
                    .context("launch failed")?,
            );
        }
        for mut proc in procs {
            let msgs = drain(&mut proc).await?;
            let seen = msgs.len() as u32;
            if seen < expected {
                lossy_runs += 1;
                lost_events += expected - seen;
                worst = worst.min(seen);
            }
        }
        done += batch;
        if done % 500 == 0 || done == args.iterations {
            println!(
                "  … {}/{} runs, {} lossy so far",
                done, args.iterations, lossy_runs
            );
        }
    }

    let elapsed = started.elapsed();
    println!(
        "\n[A] no-event-loss: {} iterations in {:.1}s ({:.0} launches/s)",
        args.iterations,
        elapsed.as_secs_f64(),
        args.iterations as f64 / elapsed.as_secs_f64()
    );
    println!("    expected {expected} events per run");
    println!("    lossy runs      : {lossy_runs} / {}", args.iterations);
    println!("    events lost     : {lost_events}");
    if lossy_runs > 0 {
        println!("    worst run saw   : {worst} / {expected}");
    }

    let pass = lossy_runs == 0;
    println!("    => {}", if pass { "PASS" } else { "FAIL" });
    Ok(pass)
}

/// Property B: cancel must reach the guest before termination.
async fn test_cancellation(args: &Args, client: &Client) -> Result<bool> {
    let input = serde_json::json!({ "count": 1, "hold_ms": 10_000 }).to_string();
    let mut proc = client
        .launch_process(args.inferlet.clone(), input, true, None)
        .await?;

    // Wait for the first emit so we know the guest is running and holding.
    let first = tokio::time::timeout(Duration::from_secs(10), proc.recv()).await??;
    if !matches!(first, ProcessEvent::Message(_)) {
        return Err(anyhow!("expected an initial message, got {first:?}"));
    }

    let sent = Instant::now();
    proc.signal(r#"{"v":1,"c":{"t":"cancel"}}"#).await?;

    // The guest should emit its own terminal frame within the grace window.
    let mut acknowledged = false;
    let deadline = Duration::from_millis(args.grace_ms);
    while sent.elapsed() < deadline {
        match tokio::time::timeout(deadline - sent.elapsed(), proc.recv()).await {
            Err(_) => break,
            Ok(Ok(ProcessEvent::Message(s))) => {
                if s.contains(r#""cancelled":true"#) {
                    acknowledged = true;
                    break;
                }
            }
            Ok(Ok(ProcessEvent::Return(_))) => break,
            Ok(Ok(_)) => {}
            Ok(Err(e)) => return Err(anyhow!("recv failed: {e}")),
        }
    }
    let latency = sent.elapsed();

    println!("\n[B] cooperative cancellation");
    println!("    guest acknowledged : {acknowledged}");
    println!("    latency            : {} ms", latency.as_millis());
    println!("    grace budget       : {} ms", args.grace_ms);

    let _ = client.terminate_process(proc.id()).await;

    println!("    => {}", if acknowledged { "PASS" } else { "FAIL" });
    Ok(acknowledged)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    eprintln!("[1/3] connecting to {} …", args.url);
    let client = tokio::time::timeout(Duration::from_secs(15), Client::connect(&args.url))
        .await
        .context("connect timed out")??;
    eprintln!("[2/3] authenticating …");
    tokio::time::timeout(Duration::from_secs(15), client.auth_by_token(&args.token))
        .await
        .context("auth_by_token timed out")??;
    eprintln!("[3/3] installing {} …", args.inferlet);
    tokio::time::timeout(
        Duration::from_secs(60),
        client.add_program(Path::new(&args.wasm), Path::new(&args.manifest), true),
    )
    .await
    .context("add_program timed out")?
    .context("add_program failed")?;
    println!("connected to {} — installed {}", args.url, args.inferlet);

    let a = test_no_loss(&args, &client).await?;
    let b = test_cancellation(&args, &client).await?;

    println!(
        "\n=== transport conformance: {} ===",
        if a && b { "PASS" } else { "FAIL" }
    );
    // `Client::close()` does not return here — it awaits a shutdown the reader
    // task never completes. Exit directly; the engine reclaims the session via
    // `Session::cleanup` (runtime/src/server.rs:400).
    std::process::exit(if a && b { 0 } else { 1 });
}
