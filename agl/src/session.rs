//! Sessions as JSONL, one event per line, flushed as written. agterm reads these files.
//!
//! Events (field `type`): `session {id, cwd, model, base_url, started}`, `user {text}`,
//! `assistant {text, reasoning}`, `tool_call {id, name, arguments}`,
//! `tool_result {id, ok, output}`, `error {message}`, `model {name}`. Every event also has
//! `ts`, milliseconds since the Unix epoch.
//!
//! While agl runs, `<home>/run/<pid>.json` holds `{"session": "<path>"}` so agterm can find the
//! conversation of the agl in a tab.

use crate::message::{Message, Role, ToolCall};
use serde_json::{Value, json};
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Session {
    pub id: String,
    pub path: PathBuf,
    file: File,
}

/// `~/.agl`, or `$AGL_HOME`.
pub fn home() -> PathBuf {
    std::env::var_os("AGL_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".agl")))
        .unwrap_or_else(|| PathBuf::from(".agl"))
}

/// `~/.agl/sessions`, or `$AGL_HOME/sessions`.
pub fn default_root() -> PathBuf {
    home().join("sessions")
}

/// The folder for sessions started in `cwd`.
pub fn dir_for(root: &Path, cwd: &Path) -> PathBuf {
    let slug: String = cwd
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '_' { c } else { '-' })
        .collect();
    root.join(slug)
}

impl Session {
    /// Starts a new session file and writes its `session` event.
    pub fn create(root: &Path, cwd: &Path, model: &str, base_url: &str) -> io::Result<Session> {
        let dir = dir_for(root, cwd);
        std::fs::create_dir_all(&dir)?;
        let now = now_utc();
        let id = new_id();
        let path = dir.join(format!("{}-{id}.jsonl", now.compact));
        let file = OpenOptions::new().create_new(true).append(true).open(&path)?;
        let mut s = Session { id: id.clone(), path, file };
        s.log("session", json!({"id": id, "cwd": cwd.to_string_lossy(), "model": model,
                                "base_url": base_url, "started": now.iso}));
        Ok(s)
    }

    /// Reopens an existing session file for appending.
    pub fn append_to(path: &Path) -> io::Result<Session> {
        let first = load(path)?.into_iter().next().unwrap_or(Value::Null);
        let id = first["id"].as_str().map(String::from).unwrap_or_else(new_id);
        let file = OpenOptions::new().append(true).open(path)?;
        Ok(Session { id, path: path.to_path_buf(), file })
    }

    /// Appends one event. A failed write is reported on stderr and otherwise ignored.
    pub fn log(&mut self, kind: &str, mut fields: Value) {
        fields["type"] = json!(kind);
        fields["ts"] = json!(SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64));
        let line = format!("{fields}\n");
        if let Err(e) = self.file.write_all(line.as_bytes()).and_then(|_| self.file.flush()) {
            eprintln!("agl: cannot write session {}: {e}", self.path.display());
        }
    }
}

fn pointer_path(root: &Path, pid: u32) -> PathBuf {
    root.parent().unwrap_or(root).join("run").join(format!("{pid}.json"))
}

/// Records that process `pid` is writing `session` with `model`. Failures are ignored: agterm
/// reads it to find the conversation, and other agl processes to see which models are in use.
pub fn write_pointer(root: &Path, pid: u32, session: &Path, model: &str) {
    let path = pointer_path(root, pid);
    let Some(dir) = path.parent() else { return };
    let tmp = dir.join(format!("{pid}.json.tmp"));
    let body = json!({"session": session.to_string_lossy(), "model": model}).to_string();
    let _ = std::fs::create_dir_all(dir).and_then(|_| std::fs::write(&tmp, body)).and_then(|_| std::fs::rename(&tmp, &path));
}

/// Removes the pointer `write_pointer` made.
pub fn remove_pointer(root: &Path, pid: u32) {
    let _ = std::fs::remove_file(pointer_path(root, pid));
}

/// Reads every event in a session file; unreadable lines are skipped.
pub fn load(path: &Path) -> io::Result<Vec<Value>> {
    let reader = BufReader::new(File::open(path)?);
    Ok(reader.lines().map_while(Result::ok).filter_map(|l| serde_json::from_str(&l).ok()).collect())
}

/// Rebuilds the conversation after `system` from saved events.
pub fn rebuild(events: &[Value], system: String) -> Vec<Message> {
    let mut msgs = vec![Message::new(Role::System, system)];
    let text = |e: &Value, k: &str| e[k].as_str().unwrap_or_default().to_string();
    for e in events {
        match e["type"].as_str() {
            Some("user") => msgs.push(Message::new(Role::User, text(e, "text"))),
            Some("assistant") => msgs.push(Message::new(Role::Assistant, text(e, "text"))),
            Some("tool_call") => {
                if let Some(last) = msgs.iter_mut().rev().find(|m| m.role == Role::Assistant) {
                    last.tool_calls.push(ToolCall {
                        id: text(e, "id"),
                        name: text(e, "name"),
                        arguments: e["arguments"].clone(),
                    });
                }
            }
            Some("tool_result") => msgs.push(Message::tool_result(&text(e, "id"), text(e, "output"))),
            _ => {}
        }
    }
    crate::message::repair(&mut msgs);
    msgs
}

/// The newest session in `cwd`'s folder, or the one whose file name contains `id`.
pub fn find(root: &Path, cwd: &Path, id: Option<&str>) -> Option<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir_for(root, cwd))
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .filter(|p| id.is_none_or(|id| p.file_name().is_some_and(|n| n.to_string_lossy().contains(id))))
        .collect();
    files.sort();
    files.pop()
}

struct Stamp {
    iso: String,
    compact: String,
}

fn now_utc() -> Stamp {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let (days, rem) = (secs / 86_400, secs % 86_400);
    let (h, m, s) = (rem / 3_600, rem % 3_600 / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days as i64);
    Stamp {
        iso: format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z"),
        compact: format!("{y:04}{mo:02}{d:02}T{h:02}{m:02}{s:02}Z"),
    }
}

/// Days since 1970-01-01 to (year, month, day). Howard Hinnant's algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// 8 hex chars from the clock and the process id.
fn new_id() -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let mixed = (nanos as u64) ^ (u64::from(std::process::id()) << 32);
    format!("{:08x}", (mixed.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 32) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::ToolResult;

    fn sample(root: &Path) -> Session {
        let mut s = Session::create(root, Path::new("/w/proj"), "qwen", "http://x/v1").unwrap();
        s.log("user", json!({"text": "fix it"}));
        s.log("assistant", json!({"text": "", "reasoning": "hmm"}));
        let call = ToolCall { id: "c1".into(), name: "read".into(), arguments: json!({"path": "a"}) };
        s.log("tool_call", json!({"id": call.id, "name": call.name, "arguments": call.arguments}));
        let r = ToolResult::ok("1\thello");
        s.log("tool_result", json!({"id": "c1", "ok": r.ok, "output": r.output}));
        s.log("assistant", json!({"text": "done", "reasoning": ""}));
        s
    }

    #[test]
    fn session_events_round_trip() {
        let root = tempfile::tempdir().unwrap();
        let s = sample(root.path());
        assert!(s.path.starts_with(dir_for(root.path(), Path::new("/w/proj"))));
        assert!(s.path.file_name().unwrap().to_str().unwrap().contains(&s.id));
        let events = load(&s.path).unwrap();
        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(kinds, vec!["session", "user", "assistant", "tool_call", "tool_result", "assistant"]);
        assert_eq!(events[0]["model"], "qwen");
        assert_eq!(events[0]["cwd"], "/w/proj");
        assert_eq!(events[0]["id"], s.id);
        assert!(events[0]["started"].as_str().unwrap().ends_with('Z'));
    }

    #[test]
    fn resume_rebuilds_messages() {
        let root = tempfile::tempdir().unwrap();
        let s = sample(root.path());
        let msgs = rebuild(&load(&s.path).unwrap(), "sys".into());
        let roles: Vec<Role> = msgs.iter().map(|m| m.role).collect();
        assert_eq!(roles, vec![Role::System, Role::User, Role::Assistant, Role::Tool, Role::Assistant]);
        assert_eq!(msgs[0].content, "sys");
        assert_eq!(msgs[2].tool_calls[0].arguments, json!({"path": "a"}));
        assert_eq!(msgs[3].tool_call_id.as_deref(), Some("c1"));
        assert_eq!(msgs[4].content, "done");
    }

    #[test]
    fn resume_after_crash_mid_tool_is_valid() {
        let root = tempfile::tempdir().unwrap();
        let mut s = Session::create(root.path(), Path::new("/w"), "m", "u").unwrap();
        s.log("user", json!({"text": "go"}));
        s.log("assistant", json!({"text": "", "reasoning": ""}));
        s.log("tool_call", json!({"id": "c1", "name": "bash", "arguments": {"command": "make"}}));
        let msgs = rebuild(&load(&s.path).unwrap(), "sys".into());
        assert_eq!(msgs.last().unwrap().tool_call_id.as_deref(), Some("c1"));
        assert_eq!(msgs.last().unwrap().content, crate::message::INTERRUPTED);
    }

    #[test]
    fn find_newest_or_by_id() {
        let root = tempfile::tempdir().unwrap();
        let a = sample(root.path());
        std::thread::sleep(std::time::Duration::from_millis(1_100));
        let b = sample(root.path());
        let cwd = Path::new("/w/proj");
        assert_eq!(find(root.path(), cwd, None), Some(b.path.clone()));
        assert_eq!(find(root.path(), cwd, Some(&a.id)), Some(a.path.clone()));
        assert_eq!(find(root.path(), Path::new("/other"), None), None);
    }

    #[test]
    fn every_event_has_a_millisecond_timestamp() {
        let root = tempfile::tempdir().unwrap();
        let s = sample(root.path());
        for e in load(&s.path).unwrap() {
            assert!(e["ts"].as_u64().unwrap() > 1_700_000_000_000, "{e}");
        }
    }

    #[test]
    fn run_pointer_names_the_session_and_goes_away() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("sessions");
        let a = Session::create(&root, Path::new("/w"), "m", "u").unwrap();
        write_pointer(&root, 4242, &a.path, "m");
        let file = home.path().join("run/4242.json");
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(v["session"], a.path.to_string_lossy().as_ref());
        let b = Session::create(&root, Path::new("/w"), "m", "u").unwrap();
        write_pointer(&root, 4242, &b.path, "m2");
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(v["session"], b.path.to_string_lossy().as_ref());
        assert_eq!(v["model"], "m2");
        remove_pointer(&root, 4242);
        assert!(!file.exists());
    }

    #[test]
    fn append_continues_file() {
        let root = tempfile::tempdir().unwrap();
        let s = sample(root.path());
        let mut again = Session::append_to(&s.path).unwrap();
        again.log("user", json!({"text": "more"}));
        assert_eq!(load(&s.path).unwrap().len(), 7);
        assert_eq!(again.id, s.id);
    }
}
