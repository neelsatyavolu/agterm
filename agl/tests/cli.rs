//! Runs the built `agl` binary against a stub model server.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::{Command, Output};

/// Serves `models` for GET and `chat` (SSE) for POST, forever.
fn stub(chat: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}/v1", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let (mut first, mut line, mut len) = (String::new(), String::new(), 0usize);
            reader.read_line(&mut first).unwrap();
            while reader.read_line(&mut line).unwrap_or(0) > 0 && line != "\r\n" {
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap_or(0);
                }
                line.clear();
            }
            let mut body = vec![0; len];
            let _ = reader.read_exact(&mut body);
            let (ctype, out) = if first.starts_with("GET") {
                ("application/json", r#"{"data":[{"id":"stub-model"}]}"#)
            } else {
                ("text/event-stream", chat)
            };
            let mut s = stream;
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{out}", out.len());
        }
    });
    base
}

fn agl(home: &std::path::Path, base: &str, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_agl"))
        .args(args)
        .env("HOME", home)
        .env("AGL_HOME", home.join(".agl"))
        .env("AGL_BASE_URL", base)
        .env_remove("AGL_MODEL")
        .current_dir(home)
        .output()
        .unwrap()
}

#[test]
fn print_config_shows_endpoint_and_detected_model() {
    let home = tempfile::tempdir().unwrap();
    let base = stub("");
    let out = agl(home.path(), &base, &["--print-config"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{stdout}{}", String::from_utf8_lossy(&out.stderr));
    assert!(stdout.contains(&format!("base_url = {base}")), "{stdout}");
    assert!(stdout.contains("model = stub-model"), "{stdout}");
}

#[test]
fn one_shot_prints_answer_and_saves_session() {
    let home = tempfile::tempdir().unwrap();
    let base = stub("data: {\"choices\":[{\"delta\":{\"content\":\"hello there\"}}]}\n\ndata: [DONE]\n\n");
    let out = agl(home.path(), &base, &["-p", "say hi"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{stdout}{}", String::from_utf8_lossy(&out.stderr));
    assert!(stdout.contains("hello there"), "{stdout}");
    let sessions = home.path().join(".agl/sessions");
    let dir = std::fs::read_dir(&sessions).unwrap().next().unwrap().unwrap().path();
    let file = std::fs::read_dir(dir).unwrap().next().unwrap().unwrap().path();
    let body = std::fs::read_to_string(file).unwrap();
    assert!(body.contains("\"type\":\"user\"") && body.contains("say hi"), "{body}");
    assert!(body.contains("hello there"), "{body}");
    let run = home.path().join(".agl/run");
    let left = std::fs::read_dir(&run).map(|d| d.count()).unwrap_or(0);
    assert_eq!(left, 0, "run pointer removed on exit");
    assert!(run.exists(), "run pointer was written");
}

#[test]
fn unreachable_endpoint_exits_2_with_one_line() {
    let home = tempfile::tempdir().unwrap();
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}/v1", l.local_addr().unwrap());
    drop(l);
    let out = Command::new(env!("CARGO_BIN_EXE_agl"))
        .args(["-p", "hi", "--model", "m"])
        .env("HOME", home.path())
        .env("AGL_HOME", home.path().join(".agl"))
        .env("AGL_BASE_URL", &base)
        .current_dir(home.path())
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{stderr}");
    assert!(stderr.contains(&format!("agl: cannot reach {base} (connection refused)")), "{stderr}");
}

fn agl_local(home: &std::path::Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_agl"))
        .args(args)
        .env("HOME", home)
        .env("AGL_HOME", home.join(".agl"))
        .env("OLLAMA_MODELS", home.join("ollama"))
        .env_remove("AGL_BASE_URL")
        .env_remove("AGL_MODEL")
        .current_dir(home)
        .output()
        .unwrap()
}

#[test]
fn models_lists_downloads_and_the_catalog() {
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".agl/models")).unwrap();
    std::fs::write(home.path().join(".agl/models/qwen3-4b.gguf"), "x").unwrap();
    let out = agl_local(home.path(), &["models"]);
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{s}");
    assert!(s.starts_with("agl\n  qwen3-4b"), "{s}");
    assert!(s.contains("qwen3-coder-30b") && s.contains("downloaded"), "{s}");
}

#[test]
fn rm_deletes_and_pull_rejects_unknown_names() {
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".agl/models")).unwrap();
    std::fs::write(home.path().join(".agl/models/mine.gguf"), "x").unwrap();
    assert!(agl_local(home.path(), &["rm", "mine"]).status.success());
    assert!(!home.path().join(".agl/models/mine.gguf").exists());
    let out = agl_local(home.path(), &["pull", "no-such-model"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("agl models"), "{}", String::from_utf8_lossy(&out.stderr));
}

#[test]
fn a_catalog_model_not_yet_downloaded_says_how_to_get_it() {
    let home = tempfile::tempdir().unwrap();
    let out = agl_local(home.path(), &["--model", "qwen3-4b", "-p", "hi"]);
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert!(err.contains("agl pull qwen3-4b"), "{err}");
}
