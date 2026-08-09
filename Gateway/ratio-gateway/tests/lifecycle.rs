use std::fs;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use pie_client::message::{ClientMessage, ServerMessage};
use tungstenite::{Message, WebSocket};

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
    let status = child
        .try_wait()
        .unwrap()
        .expect("gateway did not exit on stdin EOF");
    assert!(status.success());
    assert!(!port_file.exists(), "gateway left its port file behind");
    fs::remove_dir_all(root).unwrap();
}

fn send_response(ws: &mut WebSocket<TcpStream>, corr_id: u32, result: &str) {
    let message = ServerMessage::Response {
        corr_id,
        ok: true,
        result: result.to_string(),
    };
    ws.send(Message::Binary(
        rmp_serde::to_vec_named(&message).unwrap().into(),
    ))
    .unwrap();
}

#[test]
fn stdin_eof_forces_shutdown_with_an_open_stream() {
    let fake_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    fake_listener.set_nonblocking(true).unwrap();
    let fake_addr = fake_listener.local_addr().unwrap();
    let (stream_open_tx, stream_open_rx) = mpsc::channel();
    let fake_engine = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut accepted = 0;
        while accepted < 2 && Instant::now() < deadline {
            let connection = match fake_listener.accept() {
                Ok((connection, _)) => connection,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Err(error) => panic!("fake engine accept failed: {error}"),
            };
            connection.set_nonblocking(false).unwrap();
            accepted += 1;
            let stream_open_tx = stream_open_tx.clone();
            thread::spawn(move || {
                let mut ws = tungstenite::accept(connection).unwrap();
                while let Ok(Message::Binary(bytes)) = ws.read() {
                    let message: ClientMessage = rmp_serde::from_slice(&bytes).unwrap();
                    match message {
                        ClientMessage::AuthByToken { corr_id, .. }
                        | ClientMessage::AddProgram { corr_id, .. } => {
                            send_response(&mut ws, corr_id, "ok");
                        }
                        ClientMessage::LaunchProcess { corr_id, .. } => {
                            send_response(&mut ws, corr_id, "open-stream-process");
                            thread::sleep(Duration::from_millis(100));
                            let event = ServerMessage::ProcessEvent {
                                process_id: "open-stream-process".to_string(),
                                event: "message".to_string(),
                                value: r#"{"v":1,"seq":0,"e":{"t":"ready"}}"#.to_string(),
                            };
                            ws.send(Message::Binary(
                                rmp_serde::to_vec_named(&event).unwrap().into(),
                            ))
                            .unwrap();
                            stream_open_tx.send(()).unwrap();
                        }
                        _ => {}
                    }
                }
            });
        }
        assert_eq!(
            accepted, 2,
            "gateway opened only {accepted} fake PIE connections"
        );
    });

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
            &format!("ws://{fake_addr}"),
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

    let port = fs::read_to_string(&port_file).unwrap();
    let mut http = TcpStream::connect(format!("127.0.0.1:{}", port.trim())).unwrap();
    http.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    http.write_all(
        b"POST /v1/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
    )
    .unwrap();
    stream_open_rx.recv_timeout(Duration::from_secs(3)).unwrap();

    let mut response = [0_u8; 2048];
    let read = http.read(&mut response).unwrap();
    let response = String::from_utf8_lossy(&response[..read]);
    assert!(
        response.contains("200 OK"),
        "stream did not open: {response}"
    );

    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    let exited = child.try_wait().unwrap();

    fake_engine.join().unwrap();
    if exited.is_none() {
        child.kill().unwrap();
        child.wait().unwrap();
    }
    assert!(
        exited.is_some(),
        "gateway did not force shutdown with an open stream"
    );
    assert!(!port_file.exists(), "gateway left its port file behind");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn client_disconnect_before_first_event_terminates_process() {
    let fake_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    fake_listener.set_nonblocking(true).unwrap();
    let fake_addr = fake_listener.local_addr().unwrap();
    let (launch_tx, launch_rx) = mpsc::channel();
    let (terminated_tx, terminated_rx) = mpsc::channel();
    let fake_engine = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut accepted = 0;
        while accepted < 2 && Instant::now() < deadline {
            let connection = match fake_listener.accept() {
                Ok((connection, _)) => connection,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Err(error) => panic!("fake engine accept failed: {error}"),
            };
            connection.set_nonblocking(false).unwrap();
            accepted += 1;
            let launch_tx = launch_tx.clone();
            let terminated_tx = terminated_tx.clone();
            thread::spawn(move || {
                let mut ws = tungstenite::accept(connection).unwrap();
                while let Ok(Message::Binary(bytes)) = ws.read() {
                    let message: ClientMessage = rmp_serde::from_slice(&bytes).unwrap();
                    match message {
                        ClientMessage::AuthByToken { corr_id, .. }
                        | ClientMessage::AddProgram { corr_id, .. } => {
                            send_response(&mut ws, corr_id, "ok");
                        }
                        ClientMessage::LaunchProcess { corr_id, .. } => {
                            send_response(&mut ws, corr_id, "deferred-process");
                            launch_tx.send(()).unwrap();
                        }
                        ClientMessage::TerminateProcess {
                            corr_id,
                            process_id,
                        } => {
                            send_response(&mut ws, corr_id, "ok");
                            terminated_tx.send(process_id).unwrap();
                        }
                        _ => {}
                    }
                }
            });
        }
        assert_eq!(
            accepted, 2,
            "gateway opened only {accepted} fake PIE connections"
        );
    });

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
            &format!("ws://{fake_addr}"),
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

    let port = fs::read_to_string(&port_file).unwrap();
    let mut http = TcpStream::connect(format!("127.0.0.1:{}", port.trim())).unwrap();
    http.write_all(
        b"POST /v1/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    )
    .unwrap();
    launch_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    thread::sleep(Duration::from_millis(100));
    http.shutdown(Shutdown::Both).unwrap();
    drop(http);

    let terminated = terminated_rx
        .recv_timeout(Duration::from_secs(3))
        .expect("gateway did not terminate the pre-commit process after client disconnect");
    assert_eq!(terminated, "deferred-process");

    drop(child.stdin.take());
    child.wait().unwrap();
    fake_engine.join().unwrap();
    assert!(!port_file.exists(), "gateway left its port file behind");
    fs::remove_dir_all(root).unwrap();
}
