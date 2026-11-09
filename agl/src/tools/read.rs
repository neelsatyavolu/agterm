//! `read {path, offset?, limit?}`: numbered lines.

use super::{ToolCtx, ToolResult, num_arg, resolve, str_arg};
use serde_json::Value;

const DEFAULT_LIMIT: u64 = 2_000;

pub fn run(args: &Value, ctx: &ToolCtx) -> Result<ToolResult, String> {
    let path = str_arg(args, "path")?;
    let full = resolve(ctx, path);
    if full.is_dir() {
        return list_dir(&full, path);
    }
    let bytes = std::fs::read(&full).map_err(|e| format!("cannot read {path}: {e}"))?;
    let text = match std::str::from_utf8(&bytes) {
        Ok(t) if !bytes.iter().take(8_000).any(|b| *b == 0) => t,
        _ => return Err(format!("{path} is a binary file; use bash (e.g. `file`, `xxd | head`) to inspect it")),
    };
    let offset = num_arg(args, "offset").unwrap_or(1).max(1) as usize;
    let limit = num_arg(args, "limit").unwrap_or(DEFAULT_LIMIT).max(1) as usize;
    let lines: Vec<&str> = text.lines().collect();
    let shown: Vec<String> = lines
        .iter()
        .enumerate()
        .skip(offset - 1)
        .take(limit)
        .map(|(i, l)| format!("{:>6}\t{l}", i + 1))
        .collect();
    let last = offset - 1 + shown.len();
    let mut out = shown.join("\n");
    if shown.is_empty() {
        out = format!("[{path} has {} lines; offset {offset} is past the end]", lines.len());
    } else if last < lines.len() {
        out.push_str(&format!("\n[more: {} lines after line {last}; use offset {}]", lines.len() - last, last + 1));
    }
    Ok(ToolResult::ok(out))
}

fn list_dir(full: &std::path::Path, path: &str) -> Result<ToolResult, String> {
    let mut names: Vec<String> = std::fs::read_dir(full)
        .map_err(|e| format!("cannot list {path}: {e}"))?
        .flatten()
        .map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if e.path().is_dir() { format!("{name}/") } else { name }
        })
        .collect();
    names.sort();
    Ok(ToolResult::ok(format!("{path} is a directory:\n{}", names.join("\n"))))
}

#[cfg(test)]
mod tests {
    use crate::tools::tests::{call, ctx};
    use crate::tools::run;
    use serde_json::json;

    #[test]
    fn read_numbers_lines() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "one\ntwo\n").unwrap();
        let r = run(&call("read", json!({"path": "a.txt"})), &ctx(dir.path()));
        assert!(r.ok);
        assert_eq!(r.output, "     1\tone\n     2\ttwo");
    }

    #[test]
    fn read_offset_limit() {
        let dir = tempfile::tempdir().unwrap();
        let body: String = (1..=10).map(|i| format!("l{i}\n")).collect();
        std::fs::write(dir.path().join("a.txt"), body).unwrap();
        let r = run(&call("read", json!({"path": "a.txt", "offset": "4", "limit": 2})), &ctx(dir.path()));
        assert!(r.output.starts_with("     4\tl4\n     5\tl5"), "{}", r.output);
        assert!(r.output.contains("[more: 5 lines after line 5; use offset 6]"), "{}", r.output);
    }

    #[test]
    fn read_missing_file_is_error() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("read", json!({"path": "nope.txt"})), &ctx(dir.path()));
        assert!(!r.ok);
        assert!(r.output.contains("nope.txt"));
    }

    #[test]
    fn read_binary_file_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("b.bin"), [0u8, 159, 146, 150]).unwrap();
        let r = run(&call("read", json!({"path": "b.bin"})), &ctx(dir.path()));
        assert!(!r.ok);
        assert!(r.output.contains("binary"));
    }

    #[test]
    fn read_directory_lists_entries() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("x.rs"), "").unwrap();
        let r = run(&call("read", json!({"path": "."})), &ctx(dir.path()));
        assert!(r.ok);
        assert!(r.output.contains("x.rs"));
    }
}
