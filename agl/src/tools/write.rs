//! `write {path, content}`: create or overwrite a file.

use super::{ToolCtx, ToolResult, resolve, str_arg};
use serde_json::Value;

pub fn run(args: &Value, ctx: &ToolCtx) -> Result<ToolResult, String> {
    let path = str_arg(args, "path")?;
    let content = str_arg(args, "content")?;
    let full = resolve(ctx, path);
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }
    std::fs::write(&full, content).map_err(|e| format!("cannot write {path}: {e}"))?;
    Ok(ToolResult::ok(format!("wrote {} lines to {path}", content.lines().count())))
}

#[cfg(test)]
mod tests {
    use crate::tools::tests::{call, ctx};
    use crate::tools::run;
    use serde_json::json;

    #[test]
    fn write_creates_parents() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("write", json!({"path": "a/b/c.txt", "content": "x\ny\n"})), &ctx(dir.path()));
        assert!(r.ok, "{}", r.output);
        assert_eq!(std::fs::read_to_string(dir.path().join("a/b/c.txt")).unwrap(), "x\ny\n");
        assert_eq!(r.output, "wrote 2 lines to a/b/c.txt");
    }

    #[test]
    fn write_missing_content_is_error() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("write", json!({"path": "a.txt"})), &ctx(dir.path()));
        assert!(!r.ok);
        assert!(r.output.contains("content"));
    }
}
