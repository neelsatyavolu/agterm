//! Plain terminal output, and a wrapper that also records the session.

use crate::agent::Ui;
use crate::message::ToolCall;
use crate::session::Session;
use crate::tools::ToolResult;
use serde_json::json;
use std::io::{IsTerminal, Write, stdout};

const RESULT_PREVIEW_LINES: usize = 5;
const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const RED: &str = "\x1b[31m";
const RESET: &str = "\x1b[0m";

/// Writes the conversation to stdout; ANSI styling only when stdout is a terminal.
pub struct Term {
    color: bool,
    in_reasoning: bool,
    at_line_start: bool,
}

impl Term {
    pub fn new() -> Self {
        Self { color: stdout().is_terminal(), in_reasoning: false, at_line_start: true }
    }

    fn style(&self, code: &'static str) -> &'static str {
        if self.color { code } else { "" }
    }

    fn write(&mut self, s: &str) {
        if s.is_empty() {
            return;
        }
        let mut out = stdout().lock();
        let _ = out.write_all(s.as_bytes());
        let _ = out.flush();
        self.at_line_start = s.ends_with('\n');
    }

    fn end_reasoning(&mut self) {
        if self.in_reasoning {
            self.in_reasoning = false;
            let reset = self.style(RESET);
            self.write(&format!("{reset}\n"));
        }
    }

    fn newline(&mut self) {
        if !self.at_line_start {
            self.write("\n");
        }
    }
}

/// A one-line description of a call: `read src/main.rs`, `bash cargo test`.
pub fn summary(c: &ToolCall) -> String {
    let a = &c.arguments;
    let detail = match c.name.as_str() {
        "bash" => a["command"].as_str().unwrap_or("").lines().next().unwrap_or("").to_string(),
        _ => a["path"].as_str().unwrap_or("").to_string(),
    };
    format!("{} {detail}", c.name).trim_end().to_string()
}

impl Ui for Term {
    fn text(&mut self, s: &str) {
        self.end_reasoning();
        self.write(s);
    }

    fn reasoning(&mut self, s: &str) {
        if !self.in_reasoning {
            self.in_reasoning = true;
            let dim = self.style(DIM);
            self.write(dim);
        }
        self.write(s);
    }

    fn tool_start(&mut self, c: &ToolCall) {
        self.end_reasoning();
        self.newline();
        let (b, r) = (self.style(BOLD), self.style(RESET));
        self.write(&format!("{b}› {}{r}\n", summary(c)));
    }

    fn tool_end(&mut self, _c: &ToolCall, res: &ToolResult) {
        let (d, red, r) = (self.style(DIM), self.style(RED), self.style(RESET));
        let lines: Vec<&str> = res.output.lines().collect();
        let mut out = String::new();
        for l in lines.iter().take(RESULT_PREVIEW_LINES) {
            out.push_str(&format!("{}  {l}{r}\n", if res.ok { d } else { red }));
        }
        if lines.len() > RESULT_PREVIEW_LINES {
            out.push_str(&format!("{d}  … {} more lines{r}\n", lines.len() - RESULT_PREVIEW_LINES));
        }
        self.write(&out);
    }

    fn assistant_done(&mut self, _text: &str, _reasoning: &str) {
        self.end_reasoning();
        self.newline();
    }
}

/// Forwards to the terminal and appends each event to the session file.
pub struct Recorder<'a> {
    pub term: &'a mut dyn Ui,
    pub session: &'a mut Session,
}

impl Ui for Recorder<'_> {
    fn text(&mut self, s: &str) {
        self.term.text(s);
    }
    fn reasoning(&mut self, s: &str) {
        self.term.reasoning(s);
    }
    fn tool_start(&mut self, c: &ToolCall) {
        self.session.log("tool_call", json!({"id": c.id, "name": c.name, "arguments": c.arguments}));
        self.term.tool_start(c);
    }
    fn tool_end(&mut self, c: &ToolCall, r: &ToolResult) {
        self.session.log("tool_result", json!({"id": c.id, "ok": r.ok, "output": r.output}));
        self.term.tool_end(c, r);
    }
    fn assistant_done(&mut self, text: &str, reasoning: &str) {
        self.session.log("assistant", json!({"text": text.trim(), "reasoning": reasoning}));
        self.term.assistant_done(text, reasoning);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_shows_path_or_command() {
        let c = |n: &str, a| ToolCall { id: "x".into(), name: n.into(), arguments: a };
        assert_eq!(summary(&c("read", json!({"path": "src/a.rs"}))), "read src/a.rs");
        assert_eq!(summary(&c("bash", json!({"command": "cargo test\necho"}))), "bash cargo test");
        assert_eq!(summary(&c("bash", json!({}))), "bash");
    }
}
