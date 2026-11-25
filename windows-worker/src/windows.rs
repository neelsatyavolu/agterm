//! Installing on Windows: a copy in `%LOCALAPPDATA%\agterm`, a login item (the HKCU Run key),
//! the pairing code on the clipboard and a dialog that says what to do next.

use crate::{config, exec::no_window};
use std::{
    fs,
    io::Write,
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use windows_sys::Win32::{
    System::Console::{AttachConsole, ATTACH_PARENT_PROCESS},
    UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_ICONINFORMATION, MB_OK},
};

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "agterm worker";
const TITLE: &str = "agterm worker";

/// Lets `println!` reach the cmd or PowerShell window it was started from, if any.
pub fn attach_console() {
    // SAFETY: no pointers; fails harmlessly when there is no parent console (double-click).
    unsafe {
        AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

fn installed_exe() -> PathBuf {
    config::dir().join("agterm-worker.exe")
}

/// Installs, starts and shows the pairing code; any failure is shown in a dialog.
pub fn setup() {
    match install() {
        Ok(()) => message(
            "agterm worker is running on this PC and starts when you sign in.\n\n\
             Its pairing code is on the clipboard. In agterm on your Mac, open Settings → Macs & PCs and paste it.\n\n\
             If Windows Firewall asks, allow agterm-worker on private networks.\n\n\
             To see the code again, run: agterm-worker pair",
            false,
        ),
        Err(e) => message(&format!("Couldn't set up agterm worker: {e}"), true),
    }
}

fn install() -> Result<(), String> {
    let dir = config::dir();
    let config = config::load_or_create(&dir).map_err(|e| format!("couldn't save its settings in {}: {e}", dir.display()))?;
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let installed = installed_exe();
    if !same_file(&me, &installed) {
        // A running older copy holds the file open.
        stop_others();
        fs::copy(&me, &installed).map_err(|e| format!("couldn't copy it to {}: {e}", installed.display()))?;
    }
    let value = format!("\"{}\" serve", installed.display());
    run_quietly(Command::new("reg").args(["add", RUN_KEY, "/v", RUN_VALUE, "/t", "REG_SZ", "/d", &value, "/f"]))
        .map_err(|e| format!("couldn't add it to login items: {e}"))?;
    if !listening(config.port) {
        start_detached(&installed)?;
    }
    copy_to_clipboard(&config::code(&config::pairing(&config)))
}

/// Removes the login item, stops running copies and deletes the installed copy and its code.
pub fn uninstall() -> Result<(), String> {
    let _ = run_quietly(Command::new("reg").args(["delete", RUN_KEY, "/v", RUN_VALUE, "/f"]));
    stop_others();
    let dir = config::dir();
    let _ = fs::remove_file(dir.join("worker.json"));
    let installed = installed_exe();
    let me = std::env::current_exe().unwrap_or_default();
    if same_file(&me, &installed) {
        // A running exe can't delete itself; a shell does it once this one has exited.
        let script = format!("ping -n 3 127.0.0.1 >nul & del /f /q \"{}\"", installed.display());
        let mut cmd = Command::new("cmd");
        cmd.args(["/c", &script]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        no_window(&mut cmd);
        cmd.spawn().map_err(|e| e.to_string())?;
    } else if installed.exists() {
        fs::remove_file(&installed).map_err(|e| format!("couldn't delete {}: {e}", installed.display()))?;
    }
    println!("agterm worker is uninstalled. Remove this PC in agterm's Settings on your Mac too.");
    Ok(())
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// Ends every other agterm-worker process of this user (and the commands they run).
fn stop_others() {
    let filter = format!("PID ne {}", std::process::id());
    let _ = run_quietly(Command::new("taskkill").args(["/F", "/T", "/IM", "agterm-worker.exe", "/FI", &filter]));
    std::thread::sleep(Duration::from_millis(500));
}

fn listening(port: u16) -> bool {
    let addr: SocketAddr = ([127, 0, 0, 1], port).into();
    TcpStream::connect_timeout(&addr, Duration::from_millis(500)).is_ok()
}

fn start_detached(exe: &Path) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    Command::new(exe)
        .arg("serve")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("couldn't start it: {e}"))
}

/// Through clip.exe; the code is plain ASCII.
fn copy_to_clipboard(text: &str) -> Result<(), String> {
    let mut cmd = Command::new("clip");
    cmd.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
    no_window(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("couldn't copy the code: {e}"))?;
    child.stdin.take().map(|mut s| s.write_all(text.as_bytes())).transpose().map_err(|e| e.to_string())?;
    child.wait().map_err(|e| e.to_string())?;
    Ok(())
}

fn run_quietly(cmd: &mut Command) -> Result<(), String> {
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    no_window(cmd);
    let status = cmd.status().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{:?} exited with {status}", cmd.get_program()))
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn message(text: &str, error: bool) {
    let (text, title) = (wide(text), wide(TITLE));
    let icon = if error { MB_ICONERROR } else { MB_ICONINFORMATION };
    // SAFETY: both strings are NUL-terminated UTF-16 that outlive the call; no owner window.
    unsafe {
        MessageBoxW(std::ptr::null_mut(), text.as_ptr(), title.as_ptr(), MB_OK | icon);
    }
}
