// A GUI program on Windows, so starting at login opens no console window; CLI commands
// attach to the console they were typed in.
#![cfg_attr(windows, windows_subsystem = "windows")]

use agterm_worker::{builtin, config, server};
use std::{
    net::TcpListener,
    process::exit,
    sync::Arc,
    thread,
};

const USAGE: &str = "\
usage: agterm-worker [setup | serve | pair | new-code | uninstall | help]

setup      (or no command, as when you double-click it) installs it for this user, starts it at
           login, starts it now and copies its pairing code to the clipboard
serve      listens for paired Macs (what runs at login)
pair       prints the pairing code to paste in agterm on your Mac
new-code   makes a new secret and prints the new code; Macs with the old one must pair again
uninstall  stops it, removes it from login items and deletes the installed copy and its code";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--builtin") {
        exit(builtin::run(&args[1..]));
    }
    #[cfg(windows)]
    if args.first().map(String::as_str) != Some("serve") {
        agterm_worker::windows::attach_console();
    }
    let dir = config::dir();
    let result = match args.first().map(String::as_str) {
        None | Some("setup") => setup(),
        Some("serve") => serve(),
        Some("pair") => config::load_or_create(&dir).map(|c| println!("{}", config::code(&config::pairing(&c)))).map_err(|e| e.to_string()),
        Some("new-code") => config::new_code(&dir).map(|c| println!("{}", config::code(&config::pairing(&c)))).map_err(|e| e.to_string()),
        Some("uninstall") => uninstall(),
        Some("help" | "-h" | "--help") => {
            println!("{USAGE}");
            Ok(())
        }
        Some(other) => {
            eprintln!("agterm-worker: unknown command {other}\n\n{USAGE}");
            exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("agterm-worker: {e}");
        exit(1);
    }
}

/// Listens on IPv6 and IPv4 at the configured port; runs until killed.
fn serve() -> Result<(), String> {
    let dir = config::dir();
    let config = config::load_or_create(&dir).map_err(|e| e.to_string())?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let server = Arc::new(server::Server { dir, exe });
    // On macOS and Linux `[::]` takes IPv4 too and the second bind fails, which is fine.
    let listeners: Vec<TcpListener> = [format!("[::]:{}", config.port), format!("0.0.0.0:{}", config.port)]
        .iter()
        .filter_map(|addr| TcpListener::bind(addr).ok())
        .collect();
    if listeners.is_empty() {
        return Err(format!("port {} is in use; is agterm-worker already running?", config.port));
    }
    let threads: Vec<_> = listeners
        .into_iter()
        .map(|listener| {
            let server = server.clone();
            thread::spawn(move || server::serve(listener, server))
        })
        .collect();
    for thread in threads {
        let _ = thread.join();
    }
    Ok(())
}

#[cfg(windows)]
fn setup() -> Result<(), String> {
    agterm_worker::windows::setup();
    Ok(())
}

#[cfg(not(windows))]
fn setup() -> Result<(), String> {
    let config = config::load_or_create(&config::dir()).map_err(|e| e.to_string())?;
    println!("Setup installs it on Windows only. Run `agterm-worker serve` here; its pairing code:");
    println!("{}", config::code(&config::pairing(&config)));
    Ok(())
}

#[cfg(windows)]
fn uninstall() -> Result<(), String> {
    agterm_worker::windows::uninstall()
}

#[cfg(not(windows))]
fn uninstall() -> Result<(), String> {
    let dir = config::dir();
    match std::fs::remove_file(dir.join("worker.json")) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
