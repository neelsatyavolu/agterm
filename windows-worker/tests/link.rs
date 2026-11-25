//! The server end to end, with an OpenSSL PSK client standing in for the Mac's `MacLink`.

use agterm_worker::{
    config, crypto,
    server::{self, Server, CIPHERS},
    wire::{encode, Decoder, Message},
};
use openssl::ssl::{Ssl, SslContext, SslMethod, SslStream, SslVerifyMode, SslVersion};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    sync::Arc,
    thread,
    time::Duration,
};

struct Worker {
    port: u16,
    secret: String,
    _dir: tempfile::TempDir,
}

fn start_worker() -> Worker {
    let dir = tempfile::tempdir().unwrap();
    let config = config::load_or_create(dir.path()).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = Arc::new(Server { dir: dir.path().to_path_buf(), exe: PathBuf::from(env!("CARGO_BIN_EXE_agterm-worker")) });
    thread::spawn(move || server::serve(listener, server));
    Worker { port, secret: config.secret, _dir: dir }
}

fn connect(port: u16, secret: &str) -> SslStream<TcpStream> {
    let psk = crypto::psk(secret);
    let mut builder = SslContext::builder(SslMethod::tls_client()).unwrap();
    builder.set_min_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    builder.set_max_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    builder.set_cipher_list(CIPHERS).unwrap();
    builder.set_verify(SslVerifyMode::NONE);
    builder.set_psk_client_callback(move |_ssl, _hint, identity, out| {
        let id = crypto::PSK_IDENTITY.as_bytes();
        identity[..id.len()].copy_from_slice(id);
        identity[id.len()] = 0;
        out[..psk.len()].copy_from_slice(&psk);
        Ok(psk.len())
    });
    let tcp = TcpStream::connect(("127.0.0.1", port)).unwrap();
    tcp.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    Ssl::new(&builder.build()).unwrap().connect(tcp).unwrap()
}

/// Sends `messages`, then collects stdout, stderr and the status (or error text) until it closes.
fn exchange(stream: &mut SslStream<TcpStream>, messages: &[Message]) -> (Vec<u8>, Vec<u8>, Result<i32, String>) {
    for m in messages {
        stream.write_all(&encode(m)).unwrap();
    }
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut decoder = Decoder::default();
    let mut buf = [0u8; 65536];
    loop {
        while let Some(m) = decoder.next_message().unwrap() {
            match m {
                Message::Output(b) => out.extend(b),
                Message::Stderr(b) => err.extend(b),
                Message::Exited(status) => return (out, err, Ok(status)),
                Message::Error(text) => return (out, err, Err(text)),
                _ => {}
            }
        }
        match stream.read(&mut buf) {
            Ok(0) => return (out, err, Err("closed".into())),
            Ok(n) => decoder.push(&buf[..n]),
            Err(e) => return (out, err, Err(e.to_string())),
        }
    }
}

fn run(worker: &Worker, argv: &[&str], input: &[u8]) -> (Vec<u8>, Vec<u8>, Result<i32, String>) {
    let mut stream = connect(worker.port, &worker.secret);
    let mut messages = vec![Message::Auth(crypto::token(&worker.secret)), Message::Exec(argv.iter().map(|s| s.to_string()).collect())];
    if !input.is_empty() {
        messages.push(Message::Input(input.to_vec()));
    }
    messages.push(Message::Input(vec![]));
    exchange(&mut stream, &messages)
}

fn path(p: &Path) -> &str {
    p.to_str().unwrap()
}

#[test]
fn runs_a_shell_command_and_reports_its_status() {
    let worker = start_worker();
    let folder = tempfile::tempdir().unwrap();
    let (out, err, status) = run(&worker, &["agterm-worker", "shell", path(folder.path()), "echo hi; echo oops >&2; exit 3"], b"");
    assert_eq!(String::from_utf8_lossy(&out), "hi\n");
    assert_eq!(String::from_utf8_lossy(&err), "oops\n");
    assert_eq!(status, Ok(3));
}

#[test]
fn passes_stdin_through() {
    let worker = start_worker();
    let (out, _, status) = run(&worker, &["/bin/cat"], b"from the mac");
    assert_eq!(out, b"from the mac");
    assert_eq!(status, Ok(0));
}

#[test]
fn missing_folder_fails_like_a_command() {
    let worker = start_worker();
    let (_, err, status) = run(&worker, &["agterm-worker", "shell", "/no/such/folder", "ls"], b"");
    assert!(String::from_utf8_lossy(&err).contains("no folder"));
    assert_eq!(status, Ok(1));
}

#[test]
fn refuses_a_wrong_token() {
    let worker = start_worker();
    let mut stream = connect(worker.port, &worker.secret);
    let (_, _, status) = exchange(&mut stream, &[Message::Auth("0".repeat(64)), Message::Exec(vec!["/bin/echo".into()])]);
    assert_eq!(status, Err("unauthorized".into()));
}

#[test]
fn refuses_exec_before_auth() {
    let worker = start_worker();
    let mut stream = connect(worker.port, &worker.secret);
    let (_, _, status) = exchange(&mut stream, &[Message::Exec(vec!["/bin/echo".into()])]);
    assert_eq!(status, Err("unauthorized".into()));
}

#[test]
fn wrong_secret_fails_the_handshake() {
    let worker = start_worker();
    let psk = crypto::psk(&crypto::new_secret());
    let mut builder = SslContext::builder(SslMethod::tls_client()).unwrap();
    builder.set_cipher_list(CIPHERS).unwrap();
    builder.set_max_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    builder.set_psk_client_callback(move |_, _, identity, out| {
        identity[..10].copy_from_slice(b"agterm-mac");
        identity[10] = 0;
        out[..32].copy_from_slice(&psk);
        Ok(32)
    });
    let tcp = TcpStream::connect(("127.0.0.1", worker.port)).unwrap();
    assert!(Ssl::new(&builder.build()).unwrap().connect(tcp).is_err());
}

#[test]
fn built_ins_sync_a_folder() {
    let worker = start_worker();
    let (out, _, status) = run(&worker, &["agterm-worker", "info"], b"");
    assert_eq!(status, Ok(0));
    let info: serde_json::Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(info["shell"], "sh");

    // A tar made by the system's tar, as the Mac sends.
    let src = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(src.path().join("sub")).unwrap();
    std::fs::write(src.path().join("sub/a.txt"), "alpha").unwrap();
    let tar = std::process::Command::new("tar").args(["-cf", "-", "-C", path(src.path()), "sub/a.txt"]).output().unwrap().stdout;
    let dst = tempfile::tempdir().unwrap();
    let remote = dst.path().join("proj");
    let (_, err, status) = run(&worker, &["agterm-worker", "receive", path(&remote)], &tar);
    assert_eq!(status, Ok(0), "{}", String::from_utf8_lossy(&err));
    assert_eq!(std::fs::read_to_string(remote.join("sub/a.txt")).unwrap(), "alpha");

    let (out, _, _) = run(&worker, &["agterm-worker", "manifest", path(&remote)], b"");
    assert!(String::from_utf8_lossy(&out).starts_with("sub/a.txt\t5\t"), "{:?}", String::from_utf8_lossy(&out));

    let (packed, _, status) = run(&worker, &["agterm-worker", "pack", path(&remote)], b"sub/a.txt\0");
    assert_eq!(status, Ok(0));
    let listing = std::process::Command::new("tar")
        .arg("-tf")
        .arg("-")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            child.stdin.take().unwrap().write_all(&packed)?;
            child.wait_with_output()
        })
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&listing.stdout).trim(), "sub/a.txt");

    let (_, _, status) = run(&worker, &["agterm-worker", "delete", path(&remote)], b"sub/a.txt\0");
    assert_eq!(status, Ok(0));
    assert!(!remote.join("sub").exists() && remote.exists());
}

#[test]
fn hanging_up_stops_the_command() {
    let worker = start_worker();
    let folder = tempfile::tempdir().unwrap();
    let marker = folder.path().join("still-running");
    let mut stream = connect(worker.port, &worker.secret);
    let script = format!("sleep 2; touch '{}'", marker.display());
    for m in [Message::Auth(crypto::token(&worker.secret)), Message::Exec(vec!["agterm-worker".into(), "shell".into(), path(folder.path()).into(), script])] {
        stream.write_all(&encode(&m)).unwrap();
    }
    thread::sleep(Duration::from_millis(300));
    drop(stream);
    thread::sleep(Duration::from_secs(3));
    assert!(!marker.exists());
}
