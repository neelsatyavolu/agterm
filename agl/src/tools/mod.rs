//! The four tools: read, write, edit, bash.

mod bash;
mod edit;
mod read;
pub mod truncate;
mod write;

use crate::message::ToolCall;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Tool output above these limits is cut in the middle.
pub const MAX_OUTPUT_CHARS: usize = 30_000;
pub const MAX_OUTPUT_LINES: usize = 2_000;

pub const TOOL_NAMES: [&str; 4] = ["read", "write", "edit", "bash"];

pub struct ToolCtx {
    pub cwd: PathBuf,
    pub bash_timeout: Duration,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolResult {
    pub ok: bool,
    pub output: String,
}

impl ToolResult {
    pub fn ok(output: impl Into<String>) -> Self {
        Self { ok: true, output: output.into() }
    }
    pub fn err(output: impl Into<String>) -> Self {
        Self { ok: false, output: output.into() }
    }
}

/// OpenAI `tools` array for the four tools.
pub fn schemas() -> Value {
    let f = |name: &str, desc: &str, props: Value, req: &[&str]| {
        json!({"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": req}}})
    };
    json!([
        f("read", "Read a text file. Output lines are numbered; the numbers are not part of the file.",
          json!({"path": {"type": "string"}, "offset": {"type": "integer", "description": "First line, 1-based"},
                 "limit": {"type": "integer", "description": "Max lines (default 2000)"}}), &["path"]),
        f("write", "Create or overwrite a file with the given content.",
          json!({"path": {"type": "string"}, "content": {"type": "string"}}), &["path", "content"]),
        f("edit", "Replace the text `old` with `new` in a file. `old` must match exactly once unless replace_all is true.",
          json!({"path": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"},
                 "replace_all": {"type": "boolean"}}), &["path", "old", "new"]),
        f("bash", "Run a shell command in the working directory and return its output and exit code.",
          json!({"command": {"type": "string"}, "timeout_secs": {"type": "integer"}}), &["command"]),
    ])
}

/// Runs one call. Output is capped to the tool output limits.
pub fn run(call: &ToolCall, ctx: &ToolCtx) -> ToolResult {
    let a = &call.arguments;
    let result = match call.name.as_str() {
        "read" => read::run(a, ctx),
        "write" => write::run(a, ctx),
        "edit" => edit::run(a, ctx),
        "bash" => bash::run(a, ctx),
        other => Err(format!("unknown tool `{other}`; the tools are read, write, edit and bash")),
    };
    let r = result.unwrap_or_else(ToolResult::err);
    ToolResult { output: truncate::cap(&r.output, MAX_OUTPUT_CHARS, MAX_OUTPUT_LINES), ..r }
}

/// A required string argument.
pub(crate) fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key).and_then(Value::as_str).ok_or_else(|| format!("missing string argument `{key}`"))
}

/// An optional integer, given as a number or a numeric string.
pub(crate) fn num_arg(args: &Value, key: &str) -> Option<u64> {
    match args.get(key)? {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// An optional boolean, given as a bool or "true"/"false".
pub(crate) fn bool_arg(args: &Value, key: &str) -> bool {
    match args.get(key) {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s.trim().eq_ignore_ascii_case("true"),
        _ => false,
    }
}

/// Resolves `path` against the working directory.
pub(crate) fn resolve(ctx: &ToolCtx, path: &str) -> PathBuf {
    let p = Path::new(path);
    if p.is_absolute() { p.to_path_buf() } else { ctx.cwd.join(p) }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn ctx(dir: &Path) -> ToolCtx {
        ToolCtx { cwd: dir.to_path_buf(), bash_timeout: Duration::from_secs(10) }
    }

    pub fn call(name: &str, arguments: Value) -> ToolCall {
        ToolCall { id: "t".into(), name: name.into(), arguments }
    }

    #[test]
    fn unknown_tool_is_error() {
        let dir = tempfile::tempdir().unwrap();
        let r = run(&call("grep", json!({})), &ctx(dir.path()));
        assert!(!r.ok);
        assert!(r.output.contains("unknown tool `grep`"));
    }

    #[test]
    fn schemas_name_four_tools() {
        let names: Vec<_> = schemas().as_array().unwrap().iter().map(|t| t["function"]["name"].clone()).collect();
        assert_eq!(names, vec!["read", "write", "edit", "bash"]);
    }

    #[test]
    fn numeric_strings_coerce() {
        assert_eq!(num_arg(&json!({"n": "12"}), "n"), Some(12));
        assert_eq!(num_arg(&json!({"n": 3}), "n"), Some(3));
        assert!(bool_arg(&json!({"b": "true"}), "b"));
    }
}
