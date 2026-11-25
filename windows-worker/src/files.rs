//! The file commands the Mac uses in place of rsync, which Windows doesn't have: list what is
//! there (`manifest`), unpack a tar of what changed (`receive`), remove what was deleted
//! (`delete`), and for copying results back, list and pack files changed since a time.
//! Paths on the wire are relative, with `/`, NUL-separated.

use std::{
    fs,
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
    time::UNIX_EPOCH,
};

/// `rel` as a path under a folder, or None if it is absolute or climbs out with `..`.
pub fn safe_relative(rel: &str) -> Option<PathBuf> {
    let path = Path::new(rel);
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push(part),
            Component::CurDir => {}
            _ => return None,
        }
    }
    if out.as_os_str().is_empty() {
        return None;
    }
    Some(out)
}

fn mtime(meta: &fs::Metadata) -> u64 {
    meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0)
}

/// Calls `visit` with the relative path and metadata of every regular file under `root`,
/// without following links and without entering folders named in `skip`.
fn walk(root: &Path, skip: &[String], visit: &mut dyn FnMut(&str, &fs::Metadata) -> io::Result<()>) -> io::Result<()> {
    fn go(dir: &Path, rel: &str, skip: &[String], visit: &mut dyn FnMut(&str, &fs::Metadata) -> io::Result<()>) -> io::Result<()> {
        let mut entries: Vec<_> = fs::read_dir(dir)?.collect::<Result<_, _>>()?;
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let name = entry.file_name().to_string_lossy().into_owned();
            let meta = fs::symlink_metadata(entry.path())?;
            let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            if meta.file_type().is_symlink() {
                continue;
            }
            if meta.is_dir() {
                if !skip.iter().any(|s| s == &name) {
                    go(&entry.path(), &path, skip, visit)?;
                }
            } else if meta.is_file() {
                visit(&path, &meta)?;
            }
        }
        Ok(())
    }
    go(root, "", skip, visit)
}

/// `path\tsize\tmtime\0` for each file; nothing for a folder that isn't there.
pub fn manifest(root: &Path, skip: &[String], out: &mut dyn Write) -> io::Result<()> {
    if !root.is_dir() {
        return Ok(());
    }
    walk(root, skip, &mut |rel, meta| write!(out, "{rel}\t{}\t{}\0", meta.len(), mtime(meta)))
}

/// Files modified after `since` (Unix seconds), leaving out `.git` and the `skip` folders.
pub fn changed(root: &Path, since: u64, skip: &[String], out: &mut dyn Write) -> io::Result<()> {
    if !root.is_dir() {
        return Ok(());
    }
    let mut skip = skip.to_vec();
    skip.push(".git".into());
    walk(root, &skip, &mut |rel, meta| if mtime(meta) > since { write!(out, "{rel}\0") } else { Ok(()) })
}

fn paths(input: &mut dyn Read) -> io::Result<Vec<String>> {
    let mut data = Vec::new();
    input.read_to_end(&mut data)?;
    Ok(data.split(|&b| b == 0).filter(|p| !p.is_empty()).map(|p| String::from_utf8_lossy(p).into_owned()).collect())
}

fn make_writable(path: &Path) {
    if let Ok(meta) = fs::metadata(path) {
        let mut perms = meta.permissions();
        if perms.readonly() {
            #[allow(clippy::permissions_set_readonly_false)]
            perms.set_readonly(false);
            let _ = fs::set_permissions(path, perms);
        }
    }
}

/// Unpacks a tar under `root`. Entries that would land outside it, and links (which Windows
/// often can't make), are skipped with a note on `err`, and macOS `._` metadata files
/// silently; returns whether every entry was unpacked.
pub fn receive(root: &Path, input: &mut dyn Read, err: &mut dyn Write) -> io::Result<bool> {
    fs::create_dir_all(root)?;
    let mut archive = tar::Archive::new(input);
    archive.set_preserve_mtime(true);
    archive.set_overwrite(true);
    let mut ok = true;
    for entry in archive.entries()? {
        let mut entry = entry?;
        let name = entry.path()?.to_string_lossy().into_owned();
        let kind = entry.header().entry_type();
        let Some(rel) = safe_relative(&name) else {
            writeln!(err, "agterm-worker: skipped {name}: outside the folder")?;
            ok = false;
            continue;
        };
        // macOS tar stores extended attributes as `._name` AppleDouble files, which mean nothing here.
        if rel.file_name().is_some_and(|n| n.to_string_lossy().starts_with("._")) {
            continue;
        }
        if kind.is_symlink() || kind.is_hard_link() {
            writeln!(err, "agterm-worker: skipped link {name}")?;
            continue;
        }
        make_writable(&root.join(&rel));
        if !entry.unpack_in(root)? {
            writeln!(err, "agterm-worker: skipped {name}: outside the folder")?;
            ok = false;
        }
    }
    Ok(ok)
}

/// Removes the listed files, then any folders that became empty, never `root` itself.
pub fn delete(root: &Path, input: &mut dyn Read, err: &mut dyn Write) -> io::Result<bool> {
    let mut ok = true;
    for rel in paths(input)? {
        let Some(path) = safe_relative(&rel) else {
            writeln!(err, "agterm-worker: not deleting {rel}: outside the folder")?;
            ok = false;
            continue;
        };
        let full = root.join(&path);
        make_writable(&full);
        match fs::remove_file(&full) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => {
                writeln!(err, "agterm-worker: couldn't delete {rel}: {e}")?;
                ok = false;
                continue;
            }
        }
        let mut parent = path.parent();
        while let Some(dir) = parent.filter(|d| !d.as_os_str().is_empty()) {
            if fs::remove_dir(root.join(dir)).is_err() {
                break;
            }
            parent = dir.parent();
        }
    }
    Ok(ok)
}

/// A tar of the listed files (relative names, mtimes kept); ones that aren't there are skipped.
pub fn pack(root: &Path, input: &mut dyn Read, out: &mut dyn Write) -> io::Result<()> {
    let mut builder = tar::Builder::new(out);
    builder.follow_symlinks(false);
    for rel in paths(input)? {
        let Some(path) = safe_relative(&rel) else { continue };
        let full = root.join(&path);
        match fs::symlink_metadata(&full) {
            Ok(meta) if meta.is_file() => builder.append_path_with_name(&full, &rel)?,
            _ => continue,
        }
    }
    builder.into_inner()?.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime};

    fn write(root: &Path, rel: &str, text: &str) {
        let path = root.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn records(bytes: &[u8]) -> Vec<String> {
        bytes.split(|&b| b == 0).filter(|r| !r.is_empty()).map(|r| String::from_utf8_lossy(r).into_owned()).collect()
    }

    fn set_mtime(path: &Path, secs: u64) {
        let f = fs::File::options().write(true).open(path).unwrap();
        f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs)).unwrap();
    }

    #[test]
    fn rejects_paths_that_leave_the_folder() {
        assert!(safe_relative("../x").is_none());
        assert!(safe_relative("a/../../x").is_none());
        assert!(safe_relative("/etc/passwd").is_none());
        assert!(safe_relative("").is_none());
        assert_eq!(safe_relative("./a/b").unwrap(), PathBuf::from("a/b"));
    }

    #[test]
    fn manifest_lists_files_and_skips_folders() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "a.txt", "hello");
        write(dir.path(), "src/b.rs", "b");
        write(dir.path(), "node_modules/x/y.js", "y");
        set_mtime(&dir.path().join("a.txt"), 1_700_000_000);
        let mut out = Vec::new();
        manifest(dir.path(), &["node_modules".into()], &mut out).unwrap();
        let lines = records(&out);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], "a.txt\t5\t1700000000");
        assert!(lines[1].starts_with("src/b.rs\t1\t"));
        let mut none = Vec::new();
        manifest(&dir.path().join("missing"), &[], &mut none).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn changed_lists_newer_files_without_git() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "old.txt", "o");
        write(dir.path(), "new.txt", "n");
        write(dir.path(), ".git/index", "i");
        set_mtime(&dir.path().join("old.txt"), 1000);
        let mut out = Vec::new();
        changed(dir.path(), 2000, &[], &mut out).unwrap();
        assert_eq!(records(&out), vec!["new.txt"]);
    }

    #[test]
    fn pack_and_receive_round_trip_with_mtimes() {
        let src = tempfile::tempdir().unwrap();
        write(src.path(), "a.txt", "alpha");
        write(src.path(), "deep/b.txt", "beta");
        set_mtime(&src.path().join("a.txt"), 1_600_000_000);
        let mut tar = Vec::new();
        pack(src.path(), &mut &b"a.txt\0deep/b.txt\0missing\0../evil\0"[..], &mut tar).unwrap();

        let dst = tempfile::tempdir().unwrap();
        write(dst.path(), "a.txt", "stale");
        let mut perms = fs::metadata(dst.path().join("a.txt")).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(dst.path().join("a.txt"), perms).unwrap();
        let mut err = Vec::new();
        assert!(receive(&dst.path().join("copy"), &mut &tar[..], &mut err).unwrap());
        assert!(receive(dst.path(), &mut &tar[..], &mut err).unwrap());
        assert_eq!(fs::read_to_string(dst.path().join("a.txt")).unwrap(), "alpha");
        assert_eq!(fs::read_to_string(dst.path().join("copy/deep/b.txt")).unwrap(), "beta");
        assert_eq!(mtime(&fs::metadata(dst.path().join("a.txt")).unwrap()), 1_600_000_000);
    }

    #[test]
    fn receive_skips_entries_outside_the_folder() {
        let mut header = tar::Header::new_gnu();
        let evil = b"../evil.txt";
        header.as_gnu_mut().unwrap().name[..evil.len()].copy_from_slice(evil);
        header.set_size(1);
        header.set_mode(0o644);
        header.set_cksum();
        let mut tar = Vec::new();
        {
            let mut builder = tar::Builder::new(&mut tar);
            builder.append(&header, &b"x"[..]).unwrap();
            builder.finish().unwrap();
        }
        let dir = tempfile::tempdir().unwrap();
        let inner = dir.path().join("inner");
        let mut err = Vec::new();
        assert!(!receive(&inner, &mut &tar[..], &mut err).unwrap());
        assert!(!dir.path().join("evil.txt").exists());
        assert!(String::from_utf8_lossy(&err).contains("outside the folder"));
    }

    #[test]
    fn delete_removes_files_and_empty_folders_only() {
        let dir = tempfile::tempdir().unwrap();
        let root = &dir.path().join("root");
        write(root, "keep.txt", "k");
        write(root, "gone/deeper/x.txt", "x");
        write(root, "half/y.txt", "y");
        write(root, "half/z.txt", "z");
        let outside = dir.path().join("outside.txt");
        fs::write(&outside, "o").unwrap();
        let mut err = Vec::new();
        let ok = delete(root, &mut &b"gone/deeper/x.txt\0half/y.txt\0nothere\0../outside.txt\0"[..], &mut err).unwrap();
        assert!(!ok);
        assert!(!root.join("gone").exists());
        assert!(root.join("half/z.txt").exists() && !root.join("half/y.txt").exists());
        assert!(root.join("keep.txt").exists() && outside.exists());
    }
}
