//! `bash {command, timeout_secs?}`: `sh -c` in its own process group, output merged.

use super::{ToolCtx, ToolResult, num_arg, str_arg};
use crate::provider::CANCEL;
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Output kept in memory; the rest is drained and dropped.
const MAX_CAPTURE: usize = 8 * 1024 * 1024;
const POLL: Duration = Duration::from_millis(20);
/// How long to keep reading after exit, for output from children that hold the pipe open.
const DRAIN_GRACE: Duration = Duration::from_millis(300);

/// The longest timeout a model may ask for.
pub const MAX_TIMEOUT_SECS: u64 = 600;

pub fn run(args: &Value, ctx: &ToolCtx) -> Result<ToolResult, String> {
    run_with_cancel(args, ctx, &CANCEL)
}

/// The model's `timeout_secs`, capped at `MAX_TIMEOUT_SECS`; the configured default otherwise.
pub fn timeout_for(args: &Value, ctx: &ToolCtx) -> Duration {
    num_arg(args, "timeout_secs").map_or(ctx.bash_timeout, |s| Duration::from_secs(s.clamp(1, MAX_TIMEOUT_SECS)))
}

/// Like `run`; setting `cancel` kills the command's process group.
pub fn run_with_cancel(args: &Value, ctx: &ToolCtx, cancel: &AtomicBool) -> Result<ToolResult, String> {
    let command = str_arg(args, "command")?;
    let timeout = timeout_for(args, ctx);
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(command)
        .current_dir(&ctx.cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| format!("cannot start sh: {e}"))?;
    let buf = Arc::new(Mutex::new(Vec::new()));
    let (tx, rx) = mpsc::channel();
    spawn_reader(child.stdout.take(), Arc::clone(&buf), tx.clone());
    spawn_reader(child.stderr.take(), Arc::clone(&buf), tx);
    let status = wait_until(&mut child, Instant::now() + timeout, cancel);
    let deadline = Instant::now() + DRAIN_GRACE;
    for _ in 0..2 {
        let left = deadline.saturating_duration_since(Instant::now());
        if rx.recv_timeout(left).is_err() {
            break;
        }
    }
    let out = String::from_utf8_lossy(&buf.lock().unwrap()).trim_end().to_string();
    let sep = if out.is_empty() { "" } else { "\n" };
    Ok(match status {
        Wait::Exited(code) => ToolResult { ok: code == 0, output: format!("{out}{sep}[exit code {code}]") },
        Wait::TimedOut => ToolResult::err(format!("{out}{sep}[timed out after {}s; process killed]", timeout.as_secs())),
        Wait::Cancelled => ToolResult::err(format!("{out}{sep}[cancelled by the user; process killed]")),
    })
}

enum Wait {
    Exited(i32),
    TimedOut,
    Cancelled,
}

fn spawn_reader(pipe: Option<impl Read + Send + 'static>, buf: Arc<Mutex<Vec<u8>>>, done: mpsc::Sender<()>) {
    let Some(mut pipe) = pipe else { return };
    thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        while let Ok(n) = pipe.read(&mut chunk) {
            if n == 0 {
                break;
            }
            let mut b = buf.lock().unwrap();
            let room = MAX_CAPTURE.saturating_sub(b.len());
            b.extend_from_slice(&chunk[..n.min(room)]);
        }
        let _ = done.send(());
    });
}

/// Waits for exit; kills the process group at the deadline or when `cancel` is set.
fn wait_until(child: &mut Child, deadline: Instant, cancel: &AtomicBool) -> Wait {
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return Wait::Exited(status.code().unwrap_or(-1));
        }
        let outcome = if cancel.load(Ordering::Relaxed) {
            Wait::Cancelled
        } else if Instant::now() >= deadline {
            Wait::TimedOut
        } else {
            thread::sleep(POLL);
            continue;
        };
        // SAFETY: killpg on the group this child leads (process_group(0) above).
        unsafe { libc::killpg(child.id() as i32, libc::SIGKILL) };
        let _ = child.wait();
        return outcome;
    }
}

#[cfg(test)]
mod tests {
    use crate::tools::tests::{call, ctx};
    use crate::tools::run;
    use serde_json::json;
    use std::time::Instant;

    #[test]
    fn bash_captures_output_and_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("bash", json!({"command": "echo hi; echo oops >&2; exit 3"})), &ctx(dir.path()));
        assert!(!r.ok);
        assert!(r.output.contains("hi") && r.output.contains("oops"), "{}", r.output);
        assert!(r.output.ends_with("[exit code 3]"), "{}", r.output);
    }

    #[test]
    fn bash_success_is_ok() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("bash", json!({"command": "pwd"})), &ctx(dir.path()));
        assert!(r.ok);
        let real = dir.path().canonicalize().unwrap();
        assert!(r.output.contains(real.file_name().unwrap().to_str().unwrap()), "{}", r.output);
        assert!(r.output.ends_with("[exit code 0]"));
    }

    #[test]
    fn bash_timeout_kills_process_group() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("survived");
        let cmd = format!("(sleep 2; touch {}) & sleep 30", marker.display());
        let start = Instant::now();
        let r = run(&call("bash", json!({"command": cmd, "timeout_secs": "1"})), &ctx(dir.path()));
        assert!(start.elapsed().as_secs_f32() < 3.0, "took {:?}", start.elapsed());
        assert!(!r.ok);
        assert!(r.output.contains("timed out after 1s"), "{}", r.output);
        std::thread::sleep(std::time::Duration::from_millis(2_500));
        assert!(!marker.exists(), "background child outlived the timeout");
    }

    #[test]
    fn huge_timeout_from_model_does_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("bash", json!({"command": "echo hi", "timeout_secs": u64::MAX})), &ctx(dir.path()));
        assert!(r.ok, "{}", r.output);
        assert_eq!(super::timeout_for(&json!({"timeout_secs": 86_400}), &ctx(dir.path())).as_secs(), super::MAX_TIMEOUT_SECS);
    }

    #[test]
    fn cancel_flag_kills_running_command() {
        use std::sync::atomic::{AtomicBool, Ordering};
        static FLAG: AtomicBool = AtomicBool::new(false);
        let dir = tempfile::tempdir().unwrap();
        std::thread::spawn(|| {
            std::thread::sleep(std::time::Duration::from_millis(300));
            FLAG.store(true, Ordering::Relaxed);
        });
        let start = Instant::now();
        let r = super::run_with_cancel(&json!({"command": "sleep 30"}), &ctx(dir.path()), &FLAG).unwrap();
        assert!(start.elapsed().as_secs_f32() < 2.0, "took {:?}", start.elapsed());
        assert!(r.output.contains("cancelled"), "{}", r.output);
    }

    #[test]
    fn bash_large_output_does_not_deadlock() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("bash", json!({"command": "yes | head -c 2000000"})), &ctx(dir.path()));
        assert!(r.ok);
        assert!(r.output.contains("cut"));
    }
}
