//! One command a Mac asked for: its process, the threads that pass its stdin and output
//! through, and stopping its whole process tree if the Mac goes away first.

use crate::{shell, wire::Message};
use std::{
    io::{Read, Write},
    path::Path,
    process::{Child, Command, ExitStatus, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{channel, Sender, SyncSender},
        Arc,
    },
    thread,
};

const CHUNK: usize = 64 * 1024;

/// What the command sends back to the connection's thread.
pub enum Event {
    Message(Message),
    /// Its output has ended and it has exited, with this status.
    Exit(i32),
}

/// The process for `argv`: `agterm-worker shell <cwd> <command>` runs a command line,
/// `agterm-worker <other> …` a built-in (this exe with `--builtin`), anything else as it is.
pub fn command(argv: &[String], exe: &Path) -> Result<Command, Failure> {
    match argv {
        [] => Err(Failure::Refused("no command".into())),
        [first, rest @ ..] if first == "agterm-worker" => match rest {
            [verb, cwd, line] if verb == "shell" => {
                if !Path::new(cwd).is_dir() {
                    return Err(Failure::Exit(format!("agterm-worker: no folder {cwd} on this computer\n"), 1));
                }
                Ok(shell::command(Path::new(cwd), line))
            }
            [verb, ..] if verb == "shell" => Err(Failure::Refused("usage: agterm-worker shell <cwd> <command>".into())),
            _ => {
                let mut cmd = Command::new(exe);
                cmd.arg("--builtin").args(rest);
                Ok(cmd)
            }
        },
        [program, rest @ ..] => {
            let mut cmd = Command::new(program);
            cmd.args(rest);
            Ok(cmd)
        }
    }
}

/// Why a command didn't start.
#[derive(Debug)]
pub enum Failure {
    /// Sent as an `error` frame.
    Refused(String),
    /// Reported like a command that failed: this on stderr, then this exit status.
    Exit(String, i32),
}

/// A started command.
pub struct Running {
    pid: u32,
    stdin: Sender<Vec<u8>>,
    finished: Arc<AtomicBool>,
}

impl Running {
    /// Starts `cmd` with pipes, in its own process group, and its threads, which report on `events`.
    pub fn start(mut cmd: Command, events: SyncSender<Event>) -> std::io::Result<Running> {
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        own_group(&mut cmd);
        let mut child = cmd.spawn()?;
        let pid = child.id();
        let (stdin_tx, stdin_rx) = channel::<Vec<u8>>();
        let mut stdin = child.stdin.take();
        thread::spawn(move || {
            for bytes in stdin_rx {
                let Some(pipe) = stdin.as_mut() else { break };
                if bytes.is_empty() || pipe.write_all(&bytes).is_err() {
                    break;
                }
            }
            drop(stdin.take());
        });
        let out = pump(child.stdout.take(), events.clone(), Message::Output);
        let err = pump(child.stderr.take(), events.clone(), Message::Stderr);
        let finished = Arc::new(AtomicBool::new(false));
        let done = finished.clone();
        thread::spawn(move || {
            let _ = out.join();
            let _ = err.join();
            let status = wait(&mut child);
            done.store(true, Ordering::SeqCst);
            let _ = events.send(Event::Exit(status));
        });
        Ok(Running { pid, stdin: stdin_tx, finished })
    }

    /// Bytes for its stdin; empty ends it.
    pub fn input(&self, bytes: Vec<u8>) {
        let _ = self.stdin.send(bytes);
    }
}

impl Drop for Running {
    /// The Mac hung up, or the connection failed, while it ran: stop it and what it started.
    fn drop(&mut self) {
        if !self.finished.load(Ordering::SeqCst) {
            kill_tree(self.pid);
        }
    }
}

fn pump<R: Read + Send + 'static>(
    pipe: Option<R>,
    events: SyncSender<Event>,
    wrap: fn(Vec<u8>) -> Message,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let Some(mut pipe) = pipe else { return };
        let mut buf = vec![0u8; CHUNK];
        loop {
            match pipe.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if events.send(Event::Message(wrap(buf[..n].to_vec()))).is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    })
}

fn wait(child: &mut Child) -> i32 {
    match child.wait() {
        Ok(status) => code(status),
        Err(_) => 255,
    }
}

/// The exit code, or 128 plus the signal for a command killed by one, as a shell reports it.
fn code(status: ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return 128 + signal;
        }
    }
    status.code().unwrap_or(255)
}

#[cfg(unix)]
fn own_group(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    cmd.process_group(0);
}

#[cfg(windows)]
fn own_group(cmd: &mut Command) {
    no_window(cmd);
}

/// Children of a GUI-subsystem program would each open a console window otherwise.
#[cfg(windows)]
pub fn no_window(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(unix)]
fn kill_tree(pid: u32) {
    // SAFETY: signals the process group the child leads (it was started in its own).
    unsafe {
        libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
    }
}

#[cfg(windows)]
fn kill_tree(pid: u32) {
    let mut cmd = Command::new("taskkill");
    cmd.args(["/T", "/F", "/PID", &pid.to_string()]).stdout(Stdio::null()).stderr(Stdio::null());
    no_window(&mut cmd);
    let _ = cmd.status();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_process_for_each_kind_of_argv() {
        let exe = Path::new("/bin/agterm-worker");
        let builtin = command(&["agterm-worker".into(), "info".into()], exe).unwrap();
        assert_eq!(builtin.get_program(), exe);
        assert_eq!(builtin.get_args().collect::<Vec<_>>(), ["--builtin", "info"]);
        let plain = command(&["git".into(), "status".into()], exe).unwrap();
        assert_eq!(plain.get_program(), "git");
        assert!(matches!(command(&[], exe), Err(Failure::Refused(_))));
        let missing = command(&["agterm-worker".into(), "shell".into(), "/no/such/dir".into(), "ls".into()], exe);
        assert!(matches!(missing, Err(Failure::Exit(text, 1)) if text.contains("no folder")));
    }
}
