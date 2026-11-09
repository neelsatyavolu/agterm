//! `edit {path, old, new, replace_all?}`: exact match first, then a whitespace-tolerant match.

use super::{ToolCtx, ToolResult, bool_arg, resolve, str_arg};
use serde_json::Value;

pub fn run(args: &Value, ctx: &ToolCtx) -> Result<ToolResult, String> {
    let path = str_arg(args, "path")?;
    let old = str_arg(args, "old")?;
    let new = str_arg(args, "new")?;
    let all = bool_arg(args, "replace_all");
    if old.is_empty() {
        return Err("`old` is empty; to create a file use write".into());
    }
    let full = resolve(ctx, path);
    let text = std::fs::read_to_string(&full).map_err(|e| format!("cannot read {path}: {e}"))?;
    let mut spans = exact_spans(&text, old);
    if spans.is_empty() {
        spans = loose_spans(&text, old);
    }
    match (spans.len(), all) {
        (0, _) => Err(not_found(path, &text, old)),
        (1, _) | (_, true) => {
            let line = text[..spans[0].0].matches('\n').count() + 1;
            let mut out = text.clone();
            for (start, end) in spans.iter().rev() {
                out.replace_range(start..end, new);
            }
            std::fs::write(&full, out).map_err(|e| format!("cannot write {path}: {e}"))?;
            Ok(ToolResult::ok(match spans.len() {
                1 => format!("edited {path} at line {line}"),
                n => format!("edited {path}: {n} replacements"),
            }))
        }
        (n, false) => Err(format!("`old` appears {n} times; include more context or set replace_all")),
    }
}

/// Byte ranges of exact, non-overlapping matches.
fn exact_spans(text: &str, old: &str) -> Vec<(usize, usize)> {
    text.match_indices(old).map(|(i, m)| (i, i + m.len())).collect()
}

/// Tabs count as 4 spaces and line-end whitespace is ignored.
fn norm(line: &str) -> String {
    line.replace('\t', "    ").trim_end().to_string()
}

/// Whole-line matches after normalizing whitespace. Spans cover the matched lines without
/// the final newline.
fn loose_spans(text: &str, old: &str) -> Vec<(usize, usize)> {
    let want: Vec<String> = old.trim_matches('\n').lines().map(norm).collect();
    if want.is_empty() {
        return Vec::new();
    }
    let mut starts = Vec::new();
    let mut pos = 0;
    for l in text.split_inclusive('\n') {
        starts.push((pos, l.trim_end_matches('\n')));
        pos += l.len();
    }
    let mut spans = Vec::new();
    let mut i = 0;
    while i + want.len() <= starts.len() {
        if starts[i..i + want.len()].iter().zip(&want).all(|((_, l), w)| norm(l) == *w) {
            let (last_start, last) = starts[i + want.len() - 1];
            spans.push((starts[i].0, last_start + last.len()));
            i += want.len();
        } else {
            i += 1;
        }
    }
    spans
}

fn not_found(path: &str, text: &str, old: &str) -> String {
    let first = old.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let mut scored: Vec<(f32, usize, &str)> =
        text.lines().enumerate().map(|(i, l)| (similarity(first, l.trim()), i + 1, l)).collect();
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
    let near: Vec<String> = scored.iter().take(3).map(|(_, n, l)| format!("{n}: {l}")).collect();
    format!("`old` not found in {path}. Read the file again and copy the text exactly. Closest lines:\n{}", near.join("\n"))
}

/// Dice coefficient over character bigrams.
fn similarity(a: &str, b: &str) -> f32 {
    let grams = |s: &str| {
        let c: Vec<char> = s.chars().take(300).collect();
        let mut g: Vec<(char, char)> = c.windows(2).map(|w| (w[0], w[1])).collect();
        g.sort_unstable();
        g
    };
    let (ga, gb) = (grams(a), grams(b));
    if ga.is_empty() || gb.is_empty() {
        return 0.0;
    }
    let (mut i, mut j, mut common) = (0, 0, 0);
    while i < ga.len() && j < gb.len() {
        match ga[i].cmp(&gb[j]) {
            std::cmp::Ordering::Equal => (common, i, j) = (common + 1, i + 1, j + 1),
            std::cmp::Ordering::Less => i += 1,
            std::cmp::Ordering::Greater => j += 1,
        }
    }
    2.0 * common as f32 / (ga.len() + gb.len()) as f32
}

#[cfg(test)]
mod tests {
    use crate::tools::tests::{call, ctx};
    use crate::tools::{ToolResult, run};
    use serde_json::{Value, json};
    use std::path::Path;

    fn edit(dir: &Path, body: &str, args: Value) -> (ToolResult, String) {
        std::fs::write(dir.join("f.py"), body).unwrap();
        let mut args = args;
        args["path"] = json!("f.py");
        let r = run(&call("edit", args), &ctx(dir));
        (r, std::fs::read_to_string(dir.join("f.py")).unwrap())
    }

    #[test]
    fn edit_exact() {
        let dir = tempfile::tempdir().unwrap();
        let (r, after) = edit(dir.path(), "def add(a,b):\n    return a-b\n", json!({"old": "a-b", "new": "a+b"}));
        assert!(r.ok, "{}", r.output);
        assert_eq!(after, "def add(a,b):\n    return a+b\n");
    }

    #[test]
    fn edit_whitespace_tolerant() {
        let dir = tempfile::tempdir().unwrap();
        // File indents with a tab and has a trailing space; the model sent 4 spaces and no trailing space.
        let body = "fn f() {\n\tlet x = 1; \n\tx\n}\n";
        let (r, after) = edit(dir.path(), body, json!({"old": "    let x = 1;\n    x", "new": "\tlet x = 2;\n\tx"}));
        assert!(r.ok, "{}", r.output);
        assert_eq!(after, "fn f() {\n\tlet x = 2;\n\tx\n}\n");
    }

    #[test]
    fn edit_ambiguous_match_refused() {
        let dir = tempfile::tempdir().unwrap();
        let (r, after) = edit(dir.path(), "x = 1\nx = 1\n", json!({"old": "x = 1", "new": "x = 2"}));
        assert!(!r.ok);
        assert!(r.output.contains("appears 2 times; include more context"), "{}", r.output);
        assert_eq!(after, "x = 1\nx = 1\n");
    }

    #[test]
    fn edit_replace_all() {
        let dir = tempfile::tempdir().unwrap();
        let (r, after) = edit(dir.path(), "x = 1\nx = 1\n", json!({"old": "x = 1", "new": "x = 2", "replace_all": true}));
        assert!(r.ok);
        assert_eq!(after, "x = 2\nx = 2\n");
    }

    #[test]
    fn edit_no_match_shows_nearest_lines() {
        let dir = tempfile::tempdir().unwrap();
        let body = "def add(a, b):\n    return a - b\n\ndef sub(a, b):\n    return a - b\n";
        let (r, after) = edit(dir.path(), body, json!({"old": "def ad(a,b):", "new": "x"}));
        assert!(!r.ok);
        assert!(r.output.contains("not found"), "{}", r.output);
        assert!(r.output.contains("1: def add(a, b):"), "{}", r.output);
        assert_eq!(after, body);
    }

    #[test]
    fn edit_empty_old_refused() {
        let dir = tempfile::tempdir().unwrap();
        let (r, _) = edit(dir.path(), "a\n", json!({"old": "", "new": "b"}));
        assert!(!r.ok);
    }

    #[test]
    fn edit_reports_line() {
        let dir = tempfile::tempdir().unwrap();
        let (r, _) = edit(dir.path(), "a\nb\nc\n", json!({"old": "c", "new": "d"}));
        assert_eq!(r.output, "edited f.py at line 3");
    }
}
