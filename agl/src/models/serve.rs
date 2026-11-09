//! Starting the server a model needs: a private llama-server for GGUF files, or Ollama / LM
//! Studio when they're installed but not running. Servers agl starts are stopped by `stop`.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static CHILDREN: Mutex<Vec<Child>> = Mutex::new(Vec::new());

/// How long a model may take to load.
pub const LOAD_TIMEOUT: Duration = Duration::from_secs(300);

/// Where each runtime lives.
pub struct Runtimes {
    pub llama_server: PathBuf,
    pub ollama: PathBuf,
    pub lms: PathBuf,
    pub ollama_url: String,
    pub lmstudio_urls: Vec<String>,
}

impl Default for Runtimes {
    fn default() -> Self {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        Self {
            llama_server: which("llama-server").unwrap_or_else(|| PathBuf::from("llama-server")),
            ollama: which("ollama").unwrap_or_else(|| PathBuf::from("ollama")),
            lms: home.join(".lmstudio/bin/lms"),
            ollama_url: crate::config::DEFAULT_CANDIDATES[0].to_string(),
            lmstudio_urls: crate::config::DEFAULT_CANDIDATES[1..3].iter().map(|s| s.to_string()).collect(),
        }
    }
}

/// `name` on PATH.
pub fn which(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(name)).find(|p| p.is_file())
}

/// llama-server's arguments: the model's own chat template (`--jinja`, needed for tool calls),
/// local only.
pub fn llama_args(model: &Path, port: u16, context: u32) -> Vec<String> {
    let s = |x: &str| x.to_string();
    vec![s("-m"), model.to_string_lossy().into_owned(), s("--host"), s("127.0.0.1"), s("--port"), port.to_string(),
         s("-c"), context.to_string(), s("--jinja"), s("-ngl"), s("999")]
}

fn free_port() -> Result<u16, String> {
    std::net::TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).map(|a| a.port()).map_err(|e| e.to_string())
}

/// Runs the server and stops it when its stdin closes, which happens when agl exits for any
/// reason, SIGKILL included. Exits with the server's status.
const WATCHDOG: &str = r#"exec 3<&0
"$@" </dev/null &
server=$!
( read -r _ <&3; kill -TERM "$server" 2>/dev/null; sleep 3; kill -KILL "$server" 2>/dev/null ) &
watch=$!
wait "$server"
status=$?
kill "$watch" 2>/dev/null
exit "$status""#;

/// Spawns `bin args` under the watchdog in its own process group, logging to a temp file; kept
/// until `stop`. The child's stdin is the pipe whose closing stops it.
fn spawn(bin: &Path, args: &[String], log: &Path) -> Result<u32, String> {
    use std::os::unix::process::CommandExt;
    let out = std::fs::File::create(log).map_err(|e| format!("cannot create {}: {e}", log.display()))?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    let child = Command::new("/bin/sh")
        .args(["-c", WATCHDOG, "sh"])
        .arg(bin)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(out)
        .stderr(err)
        .process_group(0)
        .spawn()
        .map_err(|e| format!("cannot run {}: {e}", bin.display()))?;
    let pid = child.id();
    CHILDREN.lock().unwrap_or_else(|e| e.into_inner()).push(child);
    Ok(pid)
}

/// Waits until `url` answers 200, child `pid` exits, or the load times out / is cancelled.
fn wait_ready(pid: u32, url: &str, what: &str, log: &Path) -> Result<(), String> {
    let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(2))).build().into();
    let start = Instant::now();
    loop {
        if agent.get(url).call().is_ok() {
            return Ok(());
        }
        let exited = {
            let mut children = CHILDREN.lock().unwrap_or_else(|e| e.into_inner());
            let i = children.iter().position(|c| c.id() == pid);
            let status = i.and_then(|i| children[i].try_wait().ok().flatten());
            if let (Some(i), Some(_)) = (i, status) {
                let _ = children.remove(i).wait();
            }
            status
        };
        if let Some(status) = exited {
            let text = std::fs::read_to_string(log).unwrap_or_default();
            let tail: Vec<&str> = text.lines().rev().take(5).collect::<Vec<_>>().into_iter().rev().collect();
            return Err(format!("{what} exited ({status}): {}", tail.join(" / ")));
        }
        if crate::provider::CANCEL.load(std::sync::atomic::Ordering::Relaxed) {
            stop();
            return Err(format!("cancelled while starting {what}"));
        }
        if start.elapsed() > LOAD_TIMEOUT {
            stop();
            return Err(format!("{what} did not start within {}s; see {}", LOAD_TIMEOUT.as_secs(), log.display()));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Starts llama-server on `model` and waits until it answers. Returns its base URL (`…/v1`).
pub fn start_llama(bin: &Path, model: &Path, context: u32) -> Result<String, String> {
    if !bin.is_file() && which(&bin.to_string_lossy()).is_none() {
        return Err("agl runs downloaded models with llama-server, which isn't installed: brew install llama.cpp".into());
    }
    let port = free_port()?;
    let log = std::env::temp_dir().join(format!("agl-llama-server-{}-{port}.log", std::process::id()));
    let pid = spawn(bin, &llama_args(model, port, context), &log)?;
    let root = format!("http://127.0.0.1:{port}");
    wait_ready(pid, &format!("{root}/health"), "llama-server", &log)?;
    Ok(format!("{root}/v1"))
}

/// Runs `ollama serve` until agl exits, and waits for it.
pub fn start_ollama(bin: &Path, url: &str) -> Result<(), String> {
    if !bin.is_file() {
        return Err(format!("Ollama isn't running and {} isn't installed", bin.display()));
    }
    let log = std::env::temp_dir().join(format!("agl-ollama-{}.log", std::process::id()));
    let pid = spawn(bin, &["serve".to_string()], &log)?;
    wait_ready(pid, &format!("{}/models", url.trim_end_matches('/')), "ollama serve", &log)
}

/// Asks LM Studio to start its server (it keeps running after agl exits).
pub fn start_lmstudio(lms: &Path) -> Result<(), String> {
    if !lms.is_file() {
        return Err(format!("LM Studio isn't running and {} isn't installed", lms.display()));
    }
    let out = Command::new(lms).args(["server", "start"]).stdin(Stdio::null()).output()
        .map_err(|e| format!("cannot run {}: {e}", lms.display()))?;
    if out.status.success() { Ok(()) } else { Err(format!("lms server start failed: {}", String::from_utf8_lossy(&out.stderr).trim())) }
}

/// Stops every server agl started.
pub fn stop() {
    let mut children = CHILDREN.lock().unwrap_or_else(|e| e.into_inner());
    for mut c in children.drain(..) {
        // SAFETY: killpg only sends a signal to the group the child leads.
        unsafe { libc::killpg(c.id() as libc::pid_t, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(3);
        while c.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = c.kill();
        let _ = c.wait();
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// Tests that start servers share `CHILDREN` and `stop`, so they take turns.
    pub static SERIAL: Mutex<()> = Mutex::new(());
    pub fn serial() -> std::sync::MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A stand-in for llama-server or ollama: answers 200 to anything on --port (or $PORT_FROM_URL).
    pub fn fake_server(dir: &Path, delay_secs: u32) -> PathBuf {
        let p = dir.join("fake-server");
        std::fs::write(&p, format!(r#"#!/usr/bin/env python3
import sys, time, http.server
args = sys.argv[1:]
port = int(args[args.index("--port") + 1]) if "--port" in args else int(open(sys.argv[0] + ".port").read())
time.sleep({delay_secs})
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{{"data":[]}}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"#)).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    fn up(url: &str) -> bool {
        ureq::get(url).call().is_ok()
    }

    #[test]
    fn llama_args_use_the_models_template_and_stay_local() {
        let a = llama_args(Path::new("/m/x.gguf"), 8099, 32_768);
        let s = a.join(" ");
        assert!(s.contains("-m /m/x.gguf") && s.contains("--port 8099") && s.contains("--jinja"), "{s}");
        assert!(s.contains("--host 127.0.0.1") && s.contains("-c 32768"), "{s}");
    }

    #[test]
    fn start_llama_waits_for_health_and_stop_kills_it() {
        let _turn = serial();
        let d = tempfile::tempdir().unwrap();
        let bin = fake_server(d.path(), 1);
        let url = start_llama(&bin, Path::new("/m/x.gguf"), 4096).unwrap();
        assert!(url.starts_with("http://127.0.0.1:") && url.ends_with("/v1"), "{url}");
        assert!(up(&format!("{url}/models")));
        stop();
        std::thread::sleep(Duration::from_millis(300));
        assert!(!up(&format!("{url}/models")), "stopped");
    }

    #[test]
    fn a_server_dies_when_agl_dies_without_cleaning_up() {
        let _turn = serial();
        let d = tempfile::tempdir().unwrap();
        let bin = fake_server(d.path(), 0);
        let url = start_llama(&bin, Path::new("/m/x.gguf"), 4096).unwrap();
        // What a SIGKILL of agl does: its end of the watchdog's pipe closes, nothing else runs.
        let mut children = CHILDREN.lock().unwrap();
        drop(children.last_mut().unwrap().stdin.take());
        drop(children);
        std::thread::sleep(Duration::from_millis(1_500));
        assert!(!up(&format!("{url}/models")), "server outlived agl");
        stop();
    }

    #[test]
    fn start_llama_reports_a_server_that_exits() {
        let _turn = serial();
        let d = tempfile::tempdir().unwrap();
        let bin = d.path().join("dies");
        std::fs::write(&bin, "#!/bin/sh\necho 'error: bad model' >&2\nexit 1\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let err = start_llama(&bin, Path::new("/m/x.gguf"), 4096).unwrap_err();
        assert!(err.contains("exited") && err.contains("bad model"), "{err}");
    }

    #[test]
    fn missing_llama_server_says_how_to_get_it() {
        let err = start_llama(Path::new("/nonexistent/llama-server"), Path::new("/m"), 1).unwrap_err();
        assert!(err.contains("brew install llama.cpp"), "{err}");
    }

    #[test]
    fn start_ollama_runs_serve_until_stopped() {
        let _turn = serial();
        let d = tempfile::tempdir().unwrap();
        let bin = fake_server(d.path(), 0);
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        std::fs::write(d.path().join("fake-server.port"), port.to_string()).unwrap();
        let url = format!("http://127.0.0.1:{port}/v1");
        start_ollama(&bin, &url).unwrap();
        assert!(up(&format!("{url}/models")));
        stop();
    }
}
