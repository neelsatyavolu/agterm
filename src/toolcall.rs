//! Turns a streamed assistant turn into text, reasoning and tool calls.
//!
//! Local models often skip the native `tool_calls` field and write the call into the text.
//! When no native call arrives, the text is scanned for, in order: Hermes/Qwen
//! `<tool_call>{json}</tool_call>`, Qwen3-Coder `<function=NAME><parameter=K>V</parameter></function>`,
//! and a fenced ```json block holding `{"name", "arguments"|"parameters"}`.

use crate::message::ToolCall;
use crate::provider::Delta;
use crate::tools::TOOL_NAMES;
use serde_json::{Map, Value};

#[derive(Debug, Clone, PartialEq)]
pub struct CallError {
    pub id: String,
    pub name: String,
    pub message: String,
}

#[derive(Debug, Default, PartialEq)]
pub struct Turn {
    pub text: String,
    pub reasoning: String,
    pub calls: Vec<ToolCall>,
    pub errors: Vec<CallError>,
}

#[derive(Debug, Default)]
struct Partial {
    id: Option<String>,
    name: String,
    args: String,
}

/// Collects deltas for one assistant turn.
#[derive(Debug, Default)]
pub struct Accumulator {
    text: String,
    reasoning: String,
    native: Vec<Partial>,
}

impl Accumulator {
    pub fn push(&mut self, d: &Delta) {
        match d {
            Delta::Text(s) => self.text.push_str(s),
            Delta::Reasoning(s) => self.reasoning.push_str(s),
            Delta::ToolCallChunk { index, id, name, args } => {
                if self.native.len() <= *index {
                    self.native.resize_with(index + 1, Partial::default);
                }
                let p = &mut self.native[*index];
                if p.id.is_none() {
                    p.id = id.clone();
                }
                if let Some(n) = name {
                    p.name.push_str(n);
                }
                p.args.push_str(args);
            }
            Delta::Done { .. } => {}
        }
    }

    pub fn finish(self) -> Turn {
        let (think, text) = split_think(&self.text);
        let mut turn = Turn { reasoning: self.reasoning + &think, ..Turn::default() };
        let native: Vec<Partial> = self.native.into_iter().filter(|p| !p.name.is_empty()).collect();
        if native.is_empty() {
            turn.text = extract_text_calls(&text, &mut turn);
        } else {
            turn.text = text;
            for p in native {
                let id = p.id.unwrap_or_else(|| next_id(&turn));
                let parsed = if p.args.trim().is_empty() { Ok(Value::Object(Map::new())) } else { parse_args(&p.args) };
                push_call(&mut turn, id, p.name, parsed);
            }
        }
        turn
    }
}

fn next_id(turn: &Turn) -> String {
    format!("call_{}", turn.calls.len() + turn.errors.len())
}

fn push_call(turn: &mut Turn, id: String, name: String, args: Result<Value, String>) {
    match args {
        Ok(arguments) => turn.calls.push(ToolCall { id, name, arguments }),
        Err(message) => turn.errors.push(CallError { id, name, message }),
    }
}

/// Parses an arguments string; a JSON string holding JSON is decoded once more.
fn parse_args(raw: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_str(raw.trim())
        .map_err(|e| format!("arguments were not valid JSON: {e}. Send the call again with valid JSON."))?;
    normalize_args(v)
}

fn normalize_args(v: Value) -> Result<Value, String> {
    match v {
        Value::Object(_) => Ok(v),
        Value::Null => Ok(Value::Object(Map::new())),
        Value::String(s) => parse_args(&s),
        other => Err(format!("arguments must be a JSON object, got {other}")),
    }
}

/// Moves `<think>…</think>` spans (or a prefix ending in an unopened `</think>`) out of the text.
fn split_think(text: &str) -> (String, String) {
    let mut reasoning = String::new();
    let mut rest = text.to_string();
    if let Some(end) = rest.find("</think>")
        && !rest[..end].contains("<think>")
    {
        reasoning.push_str(rest[..end].trim());
        rest = rest[end + "</think>".len()..].to_string();
    }
    while let Some(start) = rest.find("<think>") {
        let body_start = start + "<think>".len();
        let (body_end, after) = match rest[body_start..].find("</think>") {
            Some(e) => (body_start + e, body_start + e + "</think>".len()),
            None => (rest.len(), rest.len()),
        };
        reasoning.push_str(rest[body_start..body_end].trim());
        rest = format!("{}{}", &rest[..start], &rest[after..]);
    }
    (reasoning, rest)
}

/// Finds text-embedded calls, records them on `turn`, and returns the text with them removed.
fn extract_text_calls(text: &str, turn: &mut Turn) -> String {
    let rest = take_blocks(text, "<tool_call>", "</tool_call>", turn, parse_tagged);
    let rest = take_blocks(&rest, "<function=", "</function>", turn, |b| parse_qwen_xml(&format!("<function={b}")));
    if !turn.calls.is_empty() || !turn.errors.is_empty() {
        return rest;
    }
    take_fenced_json(&rest, turn)
}

type Parsed = Option<(String, Result<Value, String>)>;

/// Removes every `open … close` block (an unclosed one runs to the end) that `parse` accepts.
fn take_blocks(text: &str, open: &str, close: &str, turn: &mut Turn, parse: impl Fn(&str) -> Parsed) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(open) {
        let body = &rest[start + open.len()..];
        let (inner, after) = match body.find(close) {
            Some(e) => (&body[..e], &body[e + close.len()..]),
            None => (body, ""),
        };
        out.push_str(&rest[..start]);
        match parse(inner) {
            Some((name, args)) => push_call(turn, next_id(turn), name, args),
            None => out.push_str(&rest[start..rest.len() - after.len()]),
        }
        rest = after;
    }
    out.push_str(rest);
    out
}

/// The inside of a `<tool_call>` tag: JSON `{name, arguments}` or Qwen XML.
fn parse_tagged(inner: &str) -> Parsed {
    let inner = inner.trim();
    if inner.starts_with("<function=") {
        return parse_qwen_xml(inner);
    }
    match serde_json::from_str::<Value>(inner) {
        Ok(v) => named_call(v),
        Err(e) => Some((
            guess_name(inner),
            Err(format!("arguments were not valid JSON: {e}. Send the call again with valid JSON.")),
        )),
    }
}

fn guess_name(raw: &str) -> String {
    raw.split("\"name\"")
        .nth(1)
        .and_then(|s| s.split('"').nth(1))
        .unwrap_or("unknown")
        .to_string()
}

/// `{"name": …, "arguments"|"parameters": …}` → a call; anything else → None.
fn named_call(v: Value) -> Parsed {
    let name = v.get("name")?.as_str()?.to_string();
    let args = v.get("arguments").or_else(|| v.get("parameters")).cloned().unwrap_or(Value::Null);
    Some((name, normalize_args(args)))
}

/// `<function=NAME><parameter=K>V</parameter>…` (closing `</function>` optional).
fn parse_qwen_xml(block: &str) -> Parsed {
    let after = block.strip_prefix("<function=")?;
    let name_end = after.find('>')?;
    let name = after[..name_end].trim().to_string();
    let mut args = Map::new();
    let mut rest = &after[name_end + 1..];
    while let Some(p) = rest.find("<parameter=") {
        let tail = &rest[p + "<parameter=".len()..];
        let key_end = tail.find('>')?;
        let key = tail[..key_end].trim().to_string();
        let body = &tail[key_end + 1..];
        let val_end = body.find("</parameter>").unwrap_or(body.len());
        let val = body[..val_end].strip_prefix('\n').unwrap_or(&body[..val_end]);
        let val = val.strip_suffix('\n').unwrap_or(val);
        args.insert(key, Value::String(val.to_string()));
        rest = &body[(val_end + "</parameter>".len()).min(body.len())..];
    }
    Some((name, Ok(Value::Object(args))))
}

/// A fenced code block whose JSON object names a tool.
fn take_fenced_json(text: &str, turn: &mut Turn) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find("```") {
        let body = &rest[start + 3..];
        let Some(nl) = body.find('\n') else { break };
        let lang = body[..nl].trim();
        let Some(end) = body[nl..].find("```") else { break };
        let inner = &body[nl..nl + end];
        let after = &body[nl + end + 3..];
        // A fenced block is also how answers show JSON, so only real tool names count.
        let call = if lang.is_empty() || lang == "json" {
            serde_json::from_str::<Value>(inner.trim())
                .ok()
                .and_then(named_call)
                .filter(|(name, _)| TOOL_NAMES.contains(&name.as_str()))
        } else {
            None
        };
        out.push_str(&rest[..start]);
        match call {
            Some((name, args)) => push_call(turn, next_id(turn), name, args),
            None => out.push_str(&rest[start..rest.len() - after.len()]),
        }
        rest = after;
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn from_text(s: &str) -> Turn {
        let mut a = Accumulator::default();
        a.push(&Delta::Text(s.to_string()));
        a.finish()
    }

    #[test]
    fn native_call_parsed() {
        let mut a = Accumulator::default();
        a.push(&Delta::ToolCallChunk { index: 0, id: Some("c1".into()), name: Some("read".into()), args: "{\"path\":".into() });
        a.push(&Delta::ToolCallChunk { index: 0, id: None, name: None, args: "\"a.rs\"}".into() });
        let t = a.finish();
        assert_eq!(t.calls, vec![ToolCall { id: "c1".into(), name: "read".into(), arguments: json!({"path":"a.rs"}) }]);
    }

    #[test]
    fn native_empty_args_mean_empty_object() {
        let mut a = Accumulator::default();
        a.push(&Delta::ToolCallChunk { index: 0, id: None, name: Some("ls".into()), args: String::new() });
        assert_eq!(a.finish().calls[0].arguments, json!({}));
    }

    #[test]
    fn hermes_tag_parsed() {
        let t = from_text("Reading.\n<tool_call>\n{\"name\": \"read\", \"arguments\": {\"path\": \"a.rs\"}}\n</tool_call>");
        assert_eq!(t.calls[0].name, "read");
        assert_eq!(t.calls[0].arguments, json!({"path":"a.rs"}));
        assert_eq!(t.calls[0].id, "call_0");
        assert_eq!(t.text.trim(), "Reading.");
    }

    #[test]
    fn qwen_xml_parsed() {
        let t = from_text("<function=edit><parameter=path>a.rs</parameter><parameter=old>x</parameter><parameter=new>y</parameter></function>");
        assert_eq!(t.calls[0].name, "edit");
        assert_eq!(t.calls[0].arguments, json!({"path":"a.rs","old":"x","new":"y"}));
    }

    #[test]
    fn qwen_xml_inside_tool_call_tag_parsed() {
        let t = from_text("<tool_call>\n<function=bash>\n<parameter=command>\nls -la\n</parameter>\n</function>\n</tool_call>");
        assert_eq!(t.calls[0].name, "bash");
        assert_eq!(t.calls[0].arguments, json!({"command":"ls -la"}));
        assert!(t.text.trim().is_empty());
    }

    #[test]
    fn qwen_xml_parameters_stay_strings() {
        // `old: "123"` must not become a number; tools coerce numeric strings themselves.
        let t = from_text("<function=edit><parameter=old>123</parameter><parameter=new>124</parameter></function>");
        assert_eq!(t.calls[0].arguments["old"], json!("123"));
    }

    #[test]
    fn missing_closing_tag_still_parsed() {
        let t = from_text("<tool_call>{\"name\":\"read\",\"arguments\":{\"path\":\"a\"}}");
        assert_eq!(t.calls[0].arguments["path"], "a");
    }

    #[test]
    fn unopened_think_close_splits_reasoning() {
        let t = from_text("planning here</think>\nDone.");
        assert_eq!(t.reasoning, "planning here");
        assert_eq!(t.text.trim(), "Done.");
    }

    #[test]
    fn fenced_json_parsed() {
        let t = from_text("I'll run it.\n```json\n{\"name\": \"bash\", \"parameters\": {\"command\": \"ls\"}}\n```");
        assert_eq!(t.calls[0].name, "bash");
        assert_eq!(t.calls[0].arguments, json!({"command":"ls"}));
        assert_eq!(t.text.trim(), "I'll run it.");
    }

    #[test]
    fn fenced_package_json_is_plain_text() {
        let body = "Here is the file:\n```json\n{\"name\": \"my-app\", \"version\": \"1.0.0\", \"parameters\": {}}\n```";
        let t = from_text(body);
        assert!(t.calls.is_empty() && t.errors.is_empty());
        assert_eq!(t.text, body);
    }

    #[test]
    fn fenced_json_without_name_is_plain_text() {
        let t = from_text("```json\n{\"a\": 1}\n```");
        assert!(t.calls.is_empty());
        assert!(t.text.contains("\"a\": 1"));
    }

    #[test]
    fn plain_text_has_no_calls() {
        let t = from_text("All done.");
        assert!(t.calls.is_empty() && t.errors.is_empty());
        assert_eq!(t.text, "All done.");
    }

    #[test]
    fn think_tags_go_to_reasoning() {
        let mut a = Accumulator::default();
        a.push(&Delta::Text("<think>plan it".into()));
        a.push(&Delta::Text("</think>Answer".into()));
        let t = a.finish();
        assert_eq!(t.reasoning, "plan it");
        assert_eq!(t.text, "Answer");
    }

    #[test]
    fn reasoning_deltas_collected() {
        let mut a = Accumulator::default();
        a.push(&Delta::Reasoning("a".into()));
        a.push(&Delta::Reasoning("b".into()));
        assert_eq!(a.finish().reasoning, "ab");
    }

    #[test]
    fn malformed_args_become_error_call() {
        let mut a = Accumulator::default();
        a.push(&Delta::ToolCallChunk { index: 0, id: Some("c9".into()), name: Some("read".into()), args: "{\"path\": \"a".into() });
        let t = a.finish();
        assert!(t.calls.is_empty());
        assert_eq!(t.errors[0].id, "c9");
        assert!(t.errors[0].message.starts_with("arguments were not valid JSON"), "{}", t.errors[0].message);
    }

    #[test]
    fn malformed_hermes_json_becomes_error() {
        let t = from_text("<tool_call>{\"name\": \"read\", \"arguments\": {\"path\": }</tool_call>");
        assert!(t.calls.is_empty());
        assert_eq!(t.errors.len(), 1);
    }

    #[test]
    fn two_calls_in_one_turn() {
        let t = from_text("<tool_call>{\"name\":\"read\",\"arguments\":{\"path\":\"a\"}}</tool_call><tool_call>{\"name\":\"read\",\"arguments\":{\"path\":\"b\"}}</tool_call>");
        assert_eq!(t.calls.len(), 2);
        assert_eq!(t.calls[1].id, "call_1");
        assert_eq!(t.calls[1].arguments["path"], "b");
    }

    #[test]
    fn string_encoded_arguments_decoded() {
        let t = from_text("<tool_call>{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}</tool_call>");
        assert_eq!(t.calls[0].arguments, json!({"path":"a"}));
    }
}
