//! agl's own models: GGUF files in `~/.agl/models`. A download in progress is `<name>.gguf.part`
//! and continues where it stopped.

use std::path::{Path, PathBuf};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};

/// `~/.agl/models`.
pub fn dir() -> PathBuf {
    crate::session::home().join("models")
}

/// Downloaded models: (name, file, bytes), sorted by name. Partial downloads are left out.
pub fn list(dir: &Path) -> Vec<(String, PathBuf, u64)> {
    let mut v: Vec<_> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            let name = path.file_name()?.to_str()?.strip_suffix(".gguf")?.to_string();
            let bytes = e.metadata().ok().filter(|m| m.is_file())?.len();
            Some((name, path, bytes))
        })
        .collect();
    v.sort();
    v
}

/// The file a model called `name` is saved as.
pub fn path_for(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.gguf"))
}

/// Downloads `url` to `dest`, resuming a `.part` file. `progress(done, total)` is called as bytes
/// arrive; `cancel` stops it, keeping the part file.
pub fn pull(url: &str, dest: &Path, cancel: &AtomicBool, progress: &mut dyn FnMut(u64, Option<u64>)) -> Result<(), String> {
    let part = dest.with_extension("gguf.part");
    if let Some(dir) = dest.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&part)
        .map_err(|e| format!("cannot write {}: {e}", part.display()))?;
    // Two agl processes appending to one part file would interleave bytes. A child forked
    // just now can hold an inherited copy of the lock until it execs, so retry for a second.
    // SAFETY: flock on a descriptor we own; released when `file` closes.
    let locked = (0..20).any(|i| {
        if i > 0 {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
    });
    if !locked {
        return Err(format!("another agl is already downloading {}", dest.display()));
    }
    let have = file.metadata().map_or(0, |m| m.len());
    let agent: ureq::Agent = ureq::Agent::config_builder().http_status_as_error(false).build().into();
    let mut req = agent.get(url);
    if have > 0 {
        req = req.header("Range", format!("bytes={have}-"));
    }
    let mut resp = req.call().map_err(|e| format!("cannot download {url}: {e}"))?;
    let status = resp.status().as_u16();
    // Nothing left past the end: the part file is already whole.
    if status == 416 && have > 0 {
        return std::fs::rename(&part, dest).map_err(|e| format!("cannot save {}: {e}", dest.display()));
    }
    if !(200..300).contains(&status) {
        return Err(format!("download failed: HTTP {status} from {url}"));
    }
    // 206 continues the part file; a 200 means the server sent the whole file again.
    let start = if status == 206 { have } else { 0 };
    if start == 0 {
        file.set_len(0).map_err(|e| format!("cannot write {}: {e}", part.display()))?;
    }
    let len: Option<u64> = resp.headers().get("content-length").and_then(|v| v.to_str().ok()?.parse().ok());
    let total = len.map(|n| n + start);
    let mut reader = resp.body_mut().with_config().limit(u64::MAX).reader();
    let mut buf = vec![0u8; 1 << 16];
    let mut done = start;
    progress(done, total);
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err("download cancelled; run it again to continue".into());
        }
        let n = reader.read(&mut buf).map_err(|e| format!("download interrupted after {done} bytes: {e}"))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| format!("cannot write {}: {e}", part.display()))?;
        done += n as u64;
        progress(done, total);
    }
    if total.is_some_and(|t| done < t) {
        return Err(format!("download interrupted after {done} of {} bytes", total.unwrap_or(0)));
    }
    std::fs::rename(&part, dest).map_err(|e| format!("cannot save {}: {e}", dest.display()))
}

/// Deletes a downloaded model (and any partial download of it).
pub fn remove(dir: &Path, name: &str) -> Result<(), String> {
    let file = path_for(dir, name);
    let _ = std::fs::remove_file(file.with_extension("gguf.part"));
    match std::fs::remove_file(&file) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(format!("no model called {name} in {}", dir.display())),
        Err(e) => Err(format!("cannot delete {}: {e}", file.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;

    /// Serves `data`, honouring `Range: bytes=N-`; when `cut` is set, the first response stops after that many bytes.
    fn file_server(data: Vec<u8>, cut: Option<usize>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            let mut first = true;
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let (mut line, mut from) = (String::new(), 0usize);
                while reader.read_line(&mut line).unwrap_or(0) > 0 && line != "\r\n" {
                    if let Some(v) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                        from = v.trim().trim_end_matches('-').parse().unwrap_or(0);
                    }
                    line.clear();
                }
                let mut out = stream;
                let body = &data[from..];
                let status = if from > 0 { "206 Partial Content" } else { "200 OK" };
                let _ = write!(out, "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let send = if first { cut.map_or(body.len(), |c| c.min(body.len())) } else { body.len() };
                first = false;
                let _ = out.write_all(&body[..send]);
            }
        });
        base
    }

    #[test]
    fn lists_gguf_files_but_not_partial_ones() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("b.gguf"), "bb").unwrap();
        std::fs::write(d.path().join("a.gguf"), "a").unwrap();
        std::fs::write(d.path().join("c.gguf.part"), "c").unwrap();
        std::fs::write(d.path().join("notes.txt"), "x").unwrap();
        let names: Vec<(String, u64)> = list(d.path()).into_iter().map(|(n, _, s)| (n, s)).collect();
        assert_eq!(names, vec![("a".into(), 1), ("b".into(), 2)]);
        assert!(list(&d.path().join("missing")).is_empty());
    }

    #[test]
    fn pull_downloads_and_reports_progress() {
        let d = tempfile::tempdir().unwrap();
        let data: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let url = format!("{}/m.gguf", file_server(data.clone(), None));
        let dest = path_for(d.path(), "m");
        let mut last = (0, None);
        pull(&url, &dest, &AtomicBool::new(false), &mut |done, total| last = (done, total)).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), data);
        assert_eq!(last, (100_000, Some(100_000)));
        assert!(!d.path().join("m.gguf.part").exists());
    }

    #[test]
    fn interrupted_pull_resumes_from_the_part_file() {
        let d = tempfile::tempdir().unwrap();
        let data: Vec<u8> = (0..50_000u32).map(|i| (i % 7) as u8).collect();
        let url = format!("{}/m.gguf", file_server(data.clone(), Some(20_000)));
        let dest = path_for(d.path(), "m");
        assert!(pull(&url, &dest, &AtomicBool::new(false), &mut |_, _| {}).is_err());
        assert!(!dest.exists(), "a cut download is not a model");
        assert_eq!(std::fs::metadata(d.path().join("m.gguf.part")).unwrap().len(), 20_000);
        assert!(list(d.path()).is_empty());
        pull(&url, &dest, &AtomicBool::new(false), &mut |_, _| {}).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), data);
    }

    #[test]
    fn cancelled_pull_keeps_the_part_file() {
        let d = tempfile::tempdir().unwrap();
        let url = format!("{}/m.gguf", file_server(vec![1; 10_000], None));
        let cancel = AtomicBool::new(true);
        let err = pull(&url, &path_for(d.path(), "m"), &cancel, &mut |_, _| {}).unwrap_err();
        assert!(err.contains("cancelled"), "{err}");
        cancel.store(false, Ordering::Relaxed);
        assert!(!path_for(d.path(), "m").exists());
    }

    #[test]
    fn a_second_download_of_the_same_model_is_refused() {
        let d = tempfile::tempdir().unwrap();
        let dest = path_for(d.path(), "m");
        let held = std::fs::OpenOptions::new().create(true).append(true).open(d.path().join("m.gguf.part")).unwrap();
        assert_eq!(unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&held), libc::LOCK_EX | libc::LOCK_NB) }, 0);
        let url = format!("{}/m.gguf", file_server(vec![1; 100], None));
        let err = pull(&url, &dest, &AtomicBool::new(false), &mut |_, _| {}).unwrap_err();
        assert!(err.contains("already downloading"), "{err}");
    }

    #[test]
    fn a_complete_part_file_is_finished_not_refetched() {
        let d = tempfile::tempdir().unwrap();
        let data = vec![7u8; 1000];
        std::fs::write(d.path().join("m.gguf.part"), &data).unwrap();
        let stub = crate::testutil::serve_status(416, "text/plain", String::new());
        pull(&format!("{}/m.gguf", stub.base), &path_for(d.path(), "m"), &AtomicBool::new(false), &mut |_, _| {}).unwrap();
        assert_eq!(std::fs::read(path_for(d.path(), "m")).unwrap(), data);
    }

    #[test]
    fn http_errors_are_reported() {
        let d = tempfile::tempdir().unwrap();
        let stub = crate::testutil::serve_status(404, "text/plain", "nope".into());
        let err = pull(&format!("{}/x.gguf", stub.base), &path_for(d.path(), "x"), &AtomicBool::new(false), &mut |_, _| {})
            .unwrap_err();
        assert!(err.contains("404"), "{err}");
    }

    #[test]
    fn remove_deletes_model_and_part() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a.gguf"), "a").unwrap();
        std::fs::write(d.path().join("a.gguf.part"), "a").unwrap();
        remove(d.path(), "a").unwrap();
        assert!(std::fs::read_dir(d.path()).unwrap().next().is_none());
        assert!(remove(d.path(), "a").unwrap_err().contains("no model"));
    }
}
