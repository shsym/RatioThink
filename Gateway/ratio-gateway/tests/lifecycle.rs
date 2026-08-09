use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn temp_dir() -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!("ratio-gateway-lifecycle-{nonce}"));
    fs::create_dir(&path).unwrap();
    path
}

#[test]
fn stdin_eof_stops_gateway_and_removes_port_file() {
    let root = temp_dir();
    let port_file = root.join("gateway.port");
    fs::write(root.join("echo.wasm"), b"\0asm").unwrap();
    fs::write(
        root.join("echo.Pie.toml"),
        b"[package]\nname=\"echo\"\nversion=\"1\"\n[ratio]\nprotocol=\"chat-v1\"\n",
    )
    .unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_ratio-gateway"))
        .args([
            "--listen",
            "127.0.0.1:0",
            "--pie-url",
            "ws://127.0.0.1:1",
            "--pie-token",
            "test",
            "--inferlet-dir",
        ])
        .arg(&root)
        .arg("--port-file")
        .arg(&port_file)
        .arg("--exit-on-stdin-eof")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    while !port_file.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(port_file.exists(), "gateway never published its port");

    child.stdin.take().unwrap().flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    let status = child.try_wait().unwrap().expect("gateway did not exit on stdin EOF");
    assert!(status.success());
    assert!(!port_file.exists(), "gateway left its port file behind");
    fs::remove_dir_all(root).unwrap();
}
