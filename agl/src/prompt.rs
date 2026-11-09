//! The system prompt: short on purpose, so small context windows keep room for the work.

use std::path::{Path, PathBuf};

/// Project instruction files are cut to this many chars in total.
pub const MAX_PROJECT_CHARS: usize = 8_000;

const PREAMBLE: &str = "You are agl, a coding agent working in the user's project through four tools. Do the task, then answer briefly.

Tools:
- read: read a file (lines are numbered) or list a directory
- write: create or overwrite a file
- edit: replace exact text in a file
- bash: run a shell command (ls, rg, find, git, tests, builds)

Rules:
- Read a file before editing it. Copy `old` exactly from what you read, without the line numbers.
- Use edit to change existing files; use write only for new files or full rewrites.
- Explore with bash (rg, ls, find). Run the tests or the program to check your work.
- If a tool returns an error, read it and change the call. Never repeat a failing call unchanged.
- Keep answers short and name the files you changed.
- When the task is done, stop calling tools and say what you did.";

const INSTRUCTION_FILES: [&str; 2] = ["AGENTS.md", "CLAUDE.md"];

/// Builds the system prompt for `cwd` with the given project instruction files.
pub fn system(cwd: &Path, project_files: &[(PathBuf, String)]) -> String {
    let mut out = String::from(PREAMBLE);
    if !project_files.is_empty() {
        let mut left = MAX_PROJECT_CHARS;
        out.push_str("\n\n<project_context>\nProject instructions:\n");
        for (path, body) in project_files {
            let part: String = body.chars().take(left).collect();
            left -= part.chars().count();
            out.push_str(&format!("<file path=\"{}\">\n{}\n</file>\n", path.display(), part.trim_end()));
            if left == 0 {
                break;
            }
        }
        out.push_str("</project_context>");
    }
    out.push_str(&format!("\n\n<cwd>{}</cwd>", cwd.display()));
    out
}

/// `AGENTS.md` (else `CLAUDE.md`) in `cwd` and each parent up to the git root, outermost first.
pub fn project_files(cwd: &Path) -> Vec<(PathBuf, String)> {
    let mut found = Vec::new();
    let mut dir = Some(cwd);
    while let Some(d) = dir {
        let file = INSTRUCTION_FILES
            .iter()
            .map(|n| d.join(n))
            .find_map(|p| std::fs::read_to_string(&p).ok().map(|body| (p, body)));
        found.extend(file);
        if d.join(".git").exists() {
            break;
        }
        dir = d.parent();
    }
    if dir.is_none() {
        // No git root above cwd: only cwd's own file counts.
        found.retain(|(p, _)| p.parent() == Some(cwd));
    }
    found.reverse();
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_prompt_under_budget() {
        let p = system(Path::new("/work/proj"), &[]);
        assert!(p.len() / 4 < 600, "prompt is ~{} tokens", p.len() / 4);
        for tool in ["read", "write", "edit", "bash"] {
            assert!(p.contains(&format!("- {tool}:")), "missing {tool}");
        }
        assert!(p.contains("<cwd>/work/proj</cwd>"));
        assert!(!p.contains("<project_context>"));
    }

    #[test]
    fn project_context_included_and_capped() {
        let big = "x".repeat(20_000);
        let p = system(Path::new("/w"), &[(PathBuf::from("/w/AGENTS.md"), big)]);
        assert!(p.contains("<project_context>"));
        assert!(p.contains("/w/AGENTS.md"));
        assert!(p.len() < MAX_PROJECT_CHARS + 4_000);
    }

    #[test]
    fn project_file_found_in_parent() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join(".git")).unwrap();
        std::fs::write(root.path().join("AGENTS.md"), "root rules").unwrap();
        std::fs::write(root.path().join("CLAUDE.md"), "ignored when AGENTS.md exists").unwrap();
        let sub = root.path().join("a/b");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::write(sub.join("CLAUDE.md"), "sub rules").unwrap();
        let files = project_files(&sub);
        let bodies: Vec<&str> = files.iter().map(|(_, b)| b.as_str()).collect();
        assert_eq!(bodies, vec!["root rules", "sub rules"]);
    }

    #[test]
    fn search_stops_at_git_root() {
        let outer = tempfile::tempdir().unwrap();
        std::fs::write(outer.path().join("AGENTS.md"), "outside").unwrap();
        let repo = outer.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        assert!(project_files(&repo).is_empty());
    }
}
