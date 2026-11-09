//! Unloading models agl made Ollama or LM Studio load, so closing agl (or switching models)
//! gives the memory back. Models that were loaded before agl used them stay loaded, and so do
//! models another running agl is using.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
enum Server {
    Ollama,
    LmStudio,
}

#[derive(Debug, Clone, PartialEq)]
struct Mine {
    server: Server,
    /// The server's root URL, without `/v1`.
    root: String,
    model: String,
}

static MINE: Mutex<Vec<Mine>> = Mutex::new(Vec::new());

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(2))).build().into()
}

fn root(base_url: &str) -> String {
    let b = base_url.trim_end_matches('/');
    b.strip_suffix("/v1").unwrap_or(b).to_string()
}

/// Which server `root` is, and whether it has `model` loaded. Nil for other servers.
fn probe(root: &str, model: &str) -> Option<(Server, bool)> {
    if let Ok(mut r) = agent().get(&format!("{root}/api/ps")).call()
        && let Ok(v) = r.body_mut().read_json::<Value>()
        && let Some(list) = v["models"].as_array()
    {
        let latest = format!("{model}:latest");
        let loaded = list.iter().any(|m| [&m["name"], &m["model"]].iter().any(|n| *n == model || *n == latest.as_str()));
        return Some((Server::Ollama, loaded));
    }
    let mut r = agent().get(&format!("{root}/api/v0/models/{model}")).call().ok()?;
    let v: Value = r.body_mut().read_json().ok()?;
    v["state"].as_str().map(|s| (Server::LmStudio, s == "loaded"))
}

/// Call before agl first sends `model` to `base_url`: remembers it when the server hasn't
/// loaded it yet, so agl loading it means agl unloads it.
pub fn note(base_url: &str, model: &str) {
    let root = root(base_url);
    if let Some((server, false)) = probe(&root, model) {
        let mine = Mine { server, root, model: model.to_string() };
        let mut list = MINE.lock().unwrap_or_else(|e| e.into_inner());
        if !list.contains(&mine) {
            list.push(mine);
        }
    }
}

/// Unloads what agl loaded: every model, or only `model`. Skips models `in_use` says another
/// agl is using. `lms` is LM Studio's CLI.
pub fn release(model: Option<&str>, lms: &Path, in_use: &dyn Fn(&str) -> bool) {
    let mut list = MINE.lock().unwrap_or_else(|e| e.into_inner());
    let (go, keep): (Vec<Mine>, Vec<Mine>) = list.drain(..).partition(|m| model.is_none_or(|w| m.model == w));
    *list = keep;
    drop(list);
    for m in go.into_iter().filter(|m| !in_use(&m.model)) {
        match m.server {
            Server::Ollama => {
                let _ = agent().post(&format!("{}/api/generate", m.root)).send_json(json!({"model": m.model, "keep_alive": 0}));
            }
            Server::LmStudio => {
                let _ = std::process::Command::new(lms)
                    .args(["unload", &m.model])
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
            }
        }
    }
}

/// True when another running agl's pointer (`<run>/<pid>.json`) names `model`.
pub fn used_elsewhere(run_dir: &Path, own_pid: u32, model: &str) -> bool {
    let files: Vec<PathBuf> = std::fs::read_dir(run_dir).into_iter().flatten().flatten().map(|e| e.path()).collect();
    files.iter().any(|f| {
        let Some(pid) = f.file_stem().and_then(|s| s.to_str()).and_then(|s| s.parse::<u32>().ok()) else { return false };
        // SAFETY: signal 0 only checks that the process exists. EPERM: it exists, not ours.
        let alive = pid != own_pid
            && (unsafe { libc::kill(pid as libc::pid_t, 0) } == 0
                || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM));
        alive
            && std::fs::read_to_string(f)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .is_some_and(|v| v["model"] == model)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;

    /// Answers each path from `routes` (404 otherwise) and records "METHOD path body".
    fn routed(routes: Vec<(&'static str, &'static str)>) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&seen);
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
                let mut parts = first.split_whitespace();
                let (method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
                log.lock().unwrap().push(format!("{method} {path} {}", String::from_utf8_lossy(&body)));
                let found = routes.iter().find(|(p, _)| *p == path).map(|(_, b)| *b);
                let (status, out) = found.map_or(("404 Not Found", "{}"), |b| ("200 OK", b));
                let mut s = stream;
                let _ = write!(s, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{out}", out.len());
            }
        });
        (base, seen)
    }

    /// Tests share `MINE`.
    static SERIAL: Mutex<()> = Mutex::new(());

    #[test]
    fn ollama_model_agl_loaded_is_unloaded() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (base, seen) = routed(vec![("/api/ps", r#"{"models":[{"name":"other:7b","model":"other:7b"}]}"#), ("/api/generate", "{}")]);
        note(&format!("{base}/v1"), "qwen2.5-coder:7b");
        release(None, Path::new("/nonexistent/lms"), &|_| false);
        let log = seen.lock().unwrap().clone();
        let post = log.iter().find(|l| l.starts_with("POST /api/generate ")).expect("unload sent");
        let body: Value = serde_json::from_str(post.trim_start_matches("POST /api/generate ")).unwrap();
        assert_eq!(body, json!({"model": "qwen2.5-coder:7b", "keep_alive": 0}));
    }

    #[test]
    fn a_model_loaded_before_agl_stays_loaded() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (base, seen) = routed(vec![("/api/ps", r#"{"models":[{"name":"hermes:latest","model":"hermes:latest"}]}"#)]);
        note(&format!("{base}/v1"), "hermes");
        release(None, Path::new("/nonexistent/lms"), &|_| false);
        assert!(!seen.lock().unwrap().iter().any(|l| l.starts_with("POST")));
    }

    #[test]
    fn lm_studio_unloads_with_lms_unless_another_agl_uses_it() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (base, _) = routed(vec![("/api/v0/models/qwen3.8", r#"{"id":"qwen3.8","state":"not-loaded"}"#)]);
        let d = tempfile::tempdir().unwrap();
        let lms = d.path().join("lms");
        std::fs::write(&lms, format!("#!/bin/sh\necho \"$@\" >> {}\n", d.path().join("calls").display())).unwrap();
        std::fs::set_permissions(&lms, std::fs::Permissions::from_mode(0o755)).unwrap();
        note(&format!("{base}/v1"), "qwen3.8");
        release(None, &lms, &|m| m == "qwen3.8");
        assert!(!d.path().join("calls").exists(), "another agl uses it");
        note(&format!("{base}/v1"), "qwen3.8");
        release(Some("other"), &lms, &|_| false);
        assert!(!d.path().join("calls").exists(), "only the named model");
        release(Some("qwen3.8"), &lms, &|_| false);
        assert_eq!(std::fs::read_to_string(d.path().join("calls")).unwrap(), "unload qwen3.8\n");
    }

    #[test]
    fn other_servers_are_left_alone() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (base, seen) = routed(vec![]);
        note(&format!("{base}/v1"), "m");
        release(None, Path::new("/nonexistent/lms"), &|_| false);
        assert!(!seen.lock().unwrap().iter().any(|l| l.starts_with("POST")));
    }

    #[test]
    fn used_elsewhere_reads_live_pointers_only() {
        let d = tempfile::tempdir().unwrap();
        let me = std::process::id();
        std::fs::write(d.path().join(format!("{me}.json")), r#"{"model":"a"}"#).unwrap();
        assert!(!used_elsewhere(d.path(), me, "a"), "own pointer doesn't count");
        // pid 1 (launchd) is always alive; a huge pid isn't.
        std::fs::write(d.path().join("1.json"), r#"{"model":"b"}"#).unwrap();
        std::fs::write(d.path().join("99999999.json"), r#"{"model":"c"}"#).unwrap();
        assert!(used_elsewhere(d.path(), me, "b"));
        assert!(!used_elsewhere(d.path(), me, "c"));
    }
}
