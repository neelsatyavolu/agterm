//! The worker's settings file (`worker.json`) and the pairing code made from it.

use crate::crypto;
use serde::{Deserialize, Serialize};
use std::{fs, io, net::UdpSocket, path::PathBuf};

pub const DEFAULT_PORT: u16 = 47821;
pub const CODE_PREFIX: &str = "agterm-mac:";
const MAX_NAME: usize = 63;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub secret: String,
    pub port: u16,
}

/// What a Mac pastes to use this computer; the same code format as a Mac worker's, plus
/// `system` and `addresses`, which older Macs ignore. Fields in sorted order, as the Mac writes them.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct Pairing {
    pub addresses: Vec<String>,
    pub host: String,
    pub name: String,
    pub port: u16,
    pub secret: String,
    pub system: String,
}

/// Where `worker.json` (and on Windows the installed exe) lives: `AGTERM_WORKER_DIR`, else
/// `%LOCALAPPDATA%\agterm` on Windows and `~/.agterm-worker` elsewhere.
pub fn dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("AGTERM_WORKER_DIR") {
        return PathBuf::from(dir);
    }
    if cfg!(windows) {
        let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(|| home().join("AppData/Local"));
        base.join("agterm")
    } else {
        home().join(".agterm-worker")
    }
}

pub fn home() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

fn file(dir: &std::path::Path) -> PathBuf {
    dir.join("worker.json")
}

/// The saved settings, made (with a new secret) the first time.
pub fn load_or_create(dir: &std::path::Path) -> io::Result<Config> {
    match fs::read(file(dir)) {
        Ok(bytes) => parse(&bytes),
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            let config = Config { secret: crypto::new_secret(), port: DEFAULT_PORT };
            save(dir, &config)?;
            Ok(config)
        }
        Err(e) => Err(e),
    }
}

/// The saved settings; an error if there are none yet.
pub fn load(dir: &std::path::Path) -> io::Result<Config> {
    parse(&fs::read(file(dir))?)
}

fn parse(bytes: &[u8]) -> io::Result<Config> {
    let damaged = || io::Error::new(io::ErrorKind::InvalidData, "worker.json is damaged; run `agterm-worker new-code` to make a new one");
    let config: Config = serde_json::from_slice(bytes).map_err(|_| damaged())?;
    if !crypto::valid_secret(&config.secret) || config.port == 0 {
        return Err(damaged());
    }
    Ok(config)
}

/// A new secret, keeping the port: every Mac paired with the old code must pair again.
pub fn new_code(dir: &std::path::Path) -> io::Result<Config> {
    let port = load(dir).map(|c| c.port).unwrap_or(DEFAULT_PORT);
    let config = Config { secret: crypto::new_secret(), port };
    save(dir, &config)?;
    Ok(config)
}

fn save(dir: &std::path::Path, config: &Config) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let data = serde_json::to_vec_pretty(config).map_err(io::Error::other)?;
    let path = file(dir);
    let temp = dir.join("worker.json.new");
    write_private(&temp, &data)?;
    fs::rename(&temp, &path)
}

/// Readable by this user only (on Windows, `%LOCALAPPDATA%` already is).
fn write_private(path: &std::path::Path, data: &[u8]) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
        f.write_all(data)
    }
    #[cfg(not(unix))]
    {
        fs::write(path, data)
    }
}

pub fn system() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

/// This computer's name, at most 63 characters (Bonjour's limit, which the Mac checks).
pub fn computer_name() -> String {
    let name = if cfg!(windows) { std::env::var("COMPUTERNAME").unwrap_or_default() } else { unix_hostname() };
    let name = name.trim().trim_end_matches(".local").to_string();
    let name = if name.is_empty() { "pc".to_string() } else { name };
    name.chars().take(MAX_NAME).collect()
}

#[cfg(unix)]
fn unix_hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into buf.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    if !ok {
        return String::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

#[cfg(not(unix))]
fn unix_hostname() -> String {
    String::new()
}

/// The IPv4 address this computer uses for its default route, which a Mac on the same network
/// reaches when the `.local` name doesn't resolve. Connecting a UDP socket sends nothing.
pub fn lan_addresses() -> Vec<String> {
    let found = UdpSocket::bind("0.0.0.0:0").and_then(|s| {
        s.connect("192.0.2.1:9")?;
        s.local_addr()
    });
    match found {
        Ok(addr) if !addr.ip().is_loopback() && !addr.ip().is_unspecified() => vec![addr.ip().to_string()],
        _ => vec![],
    }
}

pub fn pairing(config: &Config) -> Pairing {
    let name = computer_name();
    Pairing {
        addresses: lan_addresses(),
        host: format!("{}.local", name.to_lowercase()),
        name,
        port: config.port,
        secret: config.secret.clone(),
        system: system().to_string(),
    }
}

pub fn code(pairing: &Pairing) -> String {
    CODE_PREFIX.to_string() + &crypto::base64url(&serde_json::to_vec(pairing).expect("pairing as JSON"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use openssl::base64;

    #[test]
    fn makes_and_keeps_a_config() {
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create(dir.path()).unwrap();
        assert_eq!(first.port, DEFAULT_PORT);
        assert_eq!(load_or_create(dir.path()).unwrap(), first);
        let renewed = new_code(dir.path()).unwrap();
        assert_ne!(renewed.secret, first.secret);
        assert_eq!(load(dir.path()).unwrap(), renewed);
    }

    #[test]
    fn rejects_a_damaged_config() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("worker.json"), br#"{"secret":"x","port":1}"#).unwrap();
        assert!(load(dir.path()).is_err());
    }

    #[test]
    fn code_is_base64url_json_the_mac_reads() {
        let config = Config { secret: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ".into(), port: 47821 };
        let pairing = Pairing {
            addresses: vec!["192.168.1.5".into()],
            host: "desktop-1.local".into(),
            name: "DESKTOP-1".into(),
            port: config.port,
            secret: config.secret.clone(),
            system: "windows".into(),
        };
        let code = code(&pairing);
        let body = code.strip_prefix(CODE_PREFIX).unwrap();
        assert!(!body.contains(['+', '/', '=']));
        let mut padded = body.replace('-', "+").replace('_', "/");
        while !padded.len().is_multiple_of(4) {
            padded.push('=');
        }
        let json = base64::decode_block(&padded).unwrap();
        assert_eq!(
            String::from_utf8(json.clone()).unwrap(),
            r#"{"addresses":["192.168.1.5"],"host":"desktop-1.local","name":"DESKTOP-1","port":47821,"secret":"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ","system":"windows"}"#
        );
        assert_eq!(serde_json::from_slice::<Pairing>(&json).unwrap(), pairing);
    }

    #[test]
    fn pairing_uses_this_computer() {
        let p = pairing(&Config { secret: crypto::new_secret(), port: 5 });
        assert!(!p.name.is_empty() && p.name.len() <= MAX_NAME);
        assert!(p.host.ends_with(".local"));
        assert_eq!(p.system, system());
    }
}
