//! Streams chat completions from an OpenAI-compatible endpoint.

use crate::config::Config;
use crate::message::Message;
use crate::sse;
use serde_json::{Value, json};
use std::io::BufReader;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Set by the Ctrl-C handler; checked between stream events.
pub static CANCEL: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, PartialEq)]
pub enum Delta {
    Text(String),
    Reasoning(String),
    ToolCallChunk { index: usize, id: Option<String>, name: Option<String>, args: String },
    Done { finish_reason: Option<String> },
}

#[derive(Debug)]
pub enum ProviderError {
    Unreachable { url: String, reason: String },
    Http { status: u16, body: String },
    Stream(String),
    Cancelled,
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::Unreachable { url, reason } => write!(f, "cannot reach {url} ({reason})"),
            Self::Http { status, body } => write!(f, "model server answered {status}: {body}"),
            Self::Stream(s) => write!(f, "{s}"),
            Self::Cancelled => write!(f, "cancelled"),
        }
    }
}

/// The request body for one streamed completion.
pub fn request_body(cfg: &Config, msgs: &[Message], tools: &Value) -> Value {
    let mut body = json!({
        "model": cfg.model,
        "stream": true,
        "temperature": cfg.temperature,
        "messages": msgs.iter().map(Message::to_json).collect::<Vec<_>>(),
        // Ollama reads this; other servers ignore unknown fields.
        "options": {"num_ctx": cfg.context_window},
    });
    if tools.as_array().is_some_and(|t| !t.is_empty()) {
        body["tools"] = tools.clone();
    }
    body
}

/// Sends `msgs` and calls `on` for every delta, ending with `Delta::Done`.
pub fn stream_chat(
    cfg: &Config,
    msgs: &[Message],
    tools: &Value,
    on: &mut dyn FnMut(Delta),
) -> Result<(), ProviderError> {
    let url = format!("{}/chat/completions", cfg.base_url);
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(5)))
        .build()
        .into();
    let mut req = agent.post(&url);
    if let Some(key) = &cfg.api_key {
        req = req.header("Authorization", &format!("Bearer {key}"));
    }
    let resp = req.send_json(request_body(cfg, msgs, tools)).map_err(|e| unreachable(cfg, e))?;
    let status = resp.status().as_u16();
    let mut body = resp.into_body();
    if status != 200 {
        let text = body.read_to_string().unwrap_or_default();
        return Err(ProviderError::Http { status, body: text.chars().take(500).collect() });
    }
    let mut finish_reason = None;
    let mut done = false;
    for event in sse::parse_lines(BufReader::new(body.into_reader())) {
        if CANCEL.load(Ordering::Relaxed) {
            return Err(ProviderError::Cancelled);
        }
        let event = match event {
            Ok(sse::Event::Data(v)) => v,
            Ok(sse::Event::Done) => {
                done = true;
                break;
            }
            // The server went away mid-answer: same as not reaching it.
            Err(sse::SseError::Io(e)) => {
                return Err(ProviderError::Unreachable { url: cfg.base_url.clone(), reason: e.to_string() });
            }
            Err(e) => return Err(ProviderError::Stream(e.to_string())),
        };
        let choice = &event["choices"][0];
        if let Some(r) = choice["finish_reason"].as_str() {
            finish_reason = Some(r.to_string());
        }
        emit_deltas(&choice["delta"], on);
    }
    if !done && finish_reason.is_none() {
        return Err(ProviderError::Stream(
            "the model server closed the stream before the answer finished".into(),
        ));
    }
    on(Delta::Done { finish_reason });
    Ok(())
}

fn unreachable(cfg: &Config, e: ureq::Error) -> ProviderError {
    let reason = match &e {
        ureq::Error::Io(io) if io.kind() == std::io::ErrorKind::ConnectionRefused => {
            "connection refused".to_string()
        }
        other => other.to_string(),
    };
    ProviderError::Unreachable { url: cfg.base_url.clone(), reason }
}

fn emit_deltas(delta: &Value, on: &mut dyn FnMut(Delta)) {
    for key in ["reasoning_content", "reasoning"] {
        if let Some(s) = delta[key].as_str().filter(|s| !s.is_empty()) {
            on(Delta::Reasoning(s.to_string()));
        }
    }
    if let Some(s) = delta["content"].as_str().filter(|s| !s.is_empty()) {
        on(Delta::Text(s.to_string()));
    }
    for (pos, call) in delta["tool_calls"].as_array().into_iter().flatten().enumerate() {
        let f = &call["function"];
        on(Delta::ToolCallChunk {
            index: call["index"].as_u64().map_or(pos, |i| i as usize),
            id: call["id"].as_str().map(String::from),
            name: f["name"].as_str().map(String::from),
            args: match &f["arguments"] {
                Value::String(s) => s.clone(),
                Value::Null => String::new(),
                // Some servers send arguments as an object instead of a string.
                other => other.to_string(),
            },
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Role;
    use crate::testutil;
    use serde_json::json;

    fn cfg(base: &str) -> Config {
        Config {
            base_url: base.to_string(),
            model: "m".into(),
            api_key: None,
            context_window: 8192,
            bash_timeout_secs: 5,
            temperature: 0.2,
        }
    }

    fn run(body: &str) -> Vec<Delta> {
        let stub = testutil::serve("text/event-stream", body.to_string());
        let mut out = Vec::new();
        stream_chat(&cfg(&stub.base), &[Message::new(Role::User, "hi")], &json!([]), &mut |d| {
            out.push(d)
        })
        .unwrap();
        out
    }

    #[test]
    fn text_deltas_stream_in_order() {
        let d = run(concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\" you\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"
        ));
        assert_eq!(d[0], Delta::Text("Hi".into()));
        assert_eq!(d[1], Delta::Text(" you".into()));
        assert_eq!(d.last(), Some(&Delta::Done { finish_reason: Some("stop".into()) }));
    }

    #[test]
    fn reasoning_field_is_separate() {
        let d = run(concat!(
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"reasoning\":\"more\"}}]}\n\n",
            "data: [DONE]\n\n"
        ));
        assert_eq!(d[0], Delta::Reasoning("think".into()));
        assert_eq!(d[1], Delta::Reasoning("more".into()));
    }

    #[test]
    fn tool_call_chunks_pass_through() {
        let d = run(concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a\\\"}\"}}]}}]}\n\n",
            "data: [DONE]\n\n"
        ));
        assert_eq!(
            d[0],
            Delta::ToolCallChunk { index: 0, id: Some("c1".into()), name: Some("read".into()), args: "{\"pa".into() }
        );
        assert_eq!(d[1], Delta::ToolCallChunk { index: 0, id: None, name: None, args: "th\":\"a\"}".into() });
    }

    #[test]
    fn finish_reason_without_done_marker_is_complete() {
        let d = run("data: {\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}]}\n\n");
        assert_eq!(d.last(), Some(&Delta::Done { finish_reason: Some("stop".into()) }));
    }

    #[test]
    fn eof_without_finish_is_error() {
        let stub = testutil::serve("text/event-stream", "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n".into());
        let err = stream_chat(&cfg(&stub.base), &[], &json!([]), &mut |_| {}).unwrap_err();
        assert!(err.to_string().contains("closed the stream before the answer finished"), "{err}");
    }

    #[test]
    fn stream_cut_mid_body_is_unreachable() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 5000\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n";
        let stub = testutil::serve_raw(raw.into());
        let err = stream_chat(&cfg(&stub.base), &[], &json!([]), &mut |_| {}).unwrap_err();
        assert!(matches!(err, ProviderError::Unreachable { .. }), "{err:?}");
        assert!(err.to_string().starts_with(&format!("cannot reach {} (", stub.base)), "{err}");
    }

    #[test]
    fn request_has_stream_tools_and_num_ctx() {
        let tools = json!([{"type":"function","function":{"name":"read"}}]);
        let b = request_body(&cfg("http://x"), &[Message::new(Role::User, "hi")], &tools);
        assert_eq!(b["stream"], true);
        assert_eq!(b["model"], "m");
        assert_eq!(b["options"]["num_ctx"], 8192);
        assert_eq!(b["tools"][0]["function"]["name"], "read");
        assert_eq!(b["messages"][0]["content"], "hi");
    }

    #[test]
    fn request_body_reaches_server() {
        let stub = testutil::serve("text/event-stream", "data: [DONE]\n\n".into());
        stream_chat(&cfg(&stub.base), &[Message::new(Role::User, "ping")], &json!([]), &mut |_| {}).unwrap();
        let sent: Value = serde_json::from_str(&stub.requests.lock().unwrap()[0]).unwrap();
        assert_eq!(sent["messages"][0]["content"], "ping");
        assert_eq!(sent["stream"], true);
    }

    #[test]
    fn empty_tools_are_left_out() {
        let b = request_body(&cfg("http://x"), &[], &json!([]));
        assert!(b.get("tools").is_none());
    }

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
    }

    #[test]
    fn lmstudio_text_fixture_splits_reasoning_and_answer() {
        let d = run(&fixture("sse_lmstudio_text.txt"));
        let text: String = d.iter().filter_map(|x| if let Delta::Text(s) = x { Some(s.as_str()) } else { None }).collect();
        assert!(d.iter().any(|x| matches!(x, Delta::Reasoning(_))));
        assert!(text.trim().ends_with("friend."), "{text}");
        assert_eq!(d.last(), Some(&Delta::Done { finish_reason: Some("stop".into()) }));
    }

    #[test]
    fn lmstudio_tool_fixture_args_concatenate_to_json() {
        let d = run(&fixture("sse_lmstudio_tool.txt"));
        let mut name = None;
        let mut args = String::new();
        for x in &d {
            if let Delta::ToolCallChunk { name: n, args: a, .. } = x {
                name = name.or(n.clone());
                args.push_str(a);
            }
        }
        assert_eq!(name.as_deref(), Some("read"));
        let v: Value = serde_json::from_str(&args).unwrap();
        assert_eq!(v["path"], "src/main.rs");
    }

    #[test]
    fn http_error_status_is_reported() {
        let stub = testutil::serve_status(404, "application/json", r#"{"error":"model not found"}"#.into());
        let err = stream_chat(&cfg(&stub.base), &[], &json!([]), &mut |_| {}).unwrap_err();
        assert!(err.to_string().starts_with("model server answered 404"), "{err}");
    }

    #[test]
    fn connection_refused_is_clean_error() {
        let url = testutil::dead_url();
        let err = stream_chat(&cfg(&url), &[], &json!([]), &mut |_| {}).unwrap_err();
        let msg = err.to_string();
        assert!(msg.starts_with(&format!("cannot reach {url} (")), "{msg}");
    }
}
