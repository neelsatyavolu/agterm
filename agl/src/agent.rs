//! The agent loop: ask the model, run its tool calls, repeat until it answers without calls.

use crate::budget;
use crate::config::Config;
use crate::message::{self, Message, Role, ToolCall};
use crate::provider::{self, CANCEL, Delta, ProviderError};
use crate::toolcall::{Accumulator, Turn};
use crate::tools::{self, ToolCtx, ToolResult};
use serde_json::Value;
use std::sync::atomic::Ordering;

pub const REPEAT_LIMIT: usize = 3;
pub const REPEAT_NOTE: &str = "You have run this exact call 3 times. Try something different.";

/// A model to talk to. The real one streams from the configured endpoint.
pub trait Chat {
    fn stream(&self, msgs: &[Message], tools: &Value, on: &mut dyn FnMut(Delta)) -> Result<(), ProviderError>;
}

impl Chat for Config {
    fn stream(&self, msgs: &[Message], tools: &Value, on: &mut dyn FnMut(Delta)) -> Result<(), ProviderError> {
        provider::stream_chat(self, msgs, tools, on)
    }
}

/// Where the loop reports progress.
pub trait Ui {
    fn text(&mut self, s: &str);
    fn reasoning(&mut self, s: &str);
    fn tool_start(&mut self, c: &ToolCall);
    fn tool_end(&mut self, c: &ToolCall, r: &ToolResult);
    /// The finished assistant turn, after streaming.
    fn assistant_done(&mut self, _text: &str, _reasoning: &str) {}
}

pub struct AgentOpts {
    pub max_steps: u32,
    pub context_window: u32,
}

#[derive(Debug)]
pub enum AgentError {
    Provider(ProviderError),
    MaxSteps(u32),
}

impl std::fmt::Display for AgentError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::Provider(e) => write!(f, "{e}"),
            Self::MaxSteps(n) => write!(f, "stopped after {n} steps without a final answer"),
        }
    }
}

/// Runs model turns until one has no tool calls. `msgs` ends with the user's message.
pub fn run_turn(
    chat: &dyn Chat,
    msgs: &mut Vec<Message>,
    ctx: &ToolCtx,
    ui: &mut dyn Ui,
    opts: &AgentOpts,
) -> Result<(), AgentError> {
    let tools = tools::schemas();
    // Room for the answer, plus the tool schemas the request also carries.
    let reserve = (opts.context_window / 4).min(4_096) + (tools.to_string().len() as f32 / 3.5) as u32;
    let mut repeats = Repeats::default();
    for _ in 0..opts.max_steps {
        message::repair(msgs);
        budget::fit(msgs, opts.context_window, reserve);
        let turn = stream_turn(chat, msgs, &tools, ui)?;
        ui.assistant_done(&turn.text, &turn.reasoning);
        let mut assistant = Message::new(Role::Assistant, turn.text.trim());
        assistant.tool_calls = turn.calls.clone();
        assistant.tool_calls.extend(turn.errors.iter().map(|e| ToolCall {
            id: e.id.clone(),
            name: e.name.clone(),
            arguments: Value::Object(Default::default()),
        }));
        msgs.push(assistant);
        if turn.calls.is_empty() && turn.errors.is_empty() {
            return Ok(());
        }
        for e in &turn.errors {
            msgs.push(Message::tool_result(&e.id, &e.message));
        }
        let mut repeated = false;
        for (i, call) in turn.calls.iter().enumerate() {
            if CANCEL.load(Ordering::Relaxed) {
                // Every call needs a result, or the next request is malformed.
                for c in &turn.calls[i..] {
                    msgs.push(Message::tool_result(&c.id, "cancelled by the user"));
                }
                return Err(AgentError::Provider(ProviderError::Cancelled));
            }
            ui.tool_start(call);
            let result = tools::run(call, ctx);
            ui.tool_end(call, &result);
            msgs.push(Message::tool_result(&call.id, &result.output));
            repeated |= repeats.record(call);
        }
        // After all results: a user message between tool results breaks strict servers.
        if repeated {
            msgs.push(Message::new(Role::User, REPEAT_NOTE));
        }
    }
    Err(AgentError::MaxSteps(opts.max_steps))
}

fn stream_turn(chat: &dyn Chat, msgs: &[Message], tools: &Value, ui: &mut dyn Ui) -> Result<Turn, AgentError> {
    let mut acc = Accumulator::default();
    chat.stream(msgs, tools, &mut |d| {
        match &d {
            Delta::Text(s) => ui.text(s),
            Delta::Reasoning(s) => ui.reasoning(s),
            _ => {}
        }
        acc.push(&d);
    })
    .map_err(AgentError::Provider)?;
    Ok(acc.finish())
}

/// Counts identical consecutive calls.
#[derive(Default)]
struct Repeats {
    last: String,
    count: usize,
}

impl Repeats {
    /// True when this call makes `REPEAT_LIMIT` identical calls in a row.
    fn record(&mut self, call: &ToolCall) -> bool {
        let key = format!("{}:{}", call.name, call.arguments);
        if key == self.last {
            self.count += 1;
        } else {
            self.last = key;
            self.count = 1;
        }
        self.count == REPEAT_LIMIT
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;
    use std::path::Path;

    /// Replays scripted turns; the last one repeats forever.
    struct Script {
        turns: Vec<Vec<Delta>>,
        next: RefCell<usize>,
        seen: RefCell<Vec<Vec<Message>>>,
    }

    impl Script {
        fn new(turns: Vec<Vec<Delta>>) -> Self {
            Self { turns, next: RefCell::new(0), seen: RefCell::new(Vec::new()) }
        }
    }

    impl Chat for Script {
        fn stream(&self, msgs: &[Message], _: &Value, on: &mut dyn FnMut(Delta)) -> Result<(), ProviderError> {
            self.seen.borrow_mut().push(msgs.to_vec());
            let i = (*self.next.borrow()).min(self.turns.len() - 1);
            *self.next.borrow_mut() += 1;
            for d in &self.turns[i] {
                on(d.clone());
            }
            on(Delta::Done { finish_reason: None });
            Ok(())
        }
    }

    #[derive(Default)]
    struct Log(Vec<String>);
    impl Ui for Log {
        fn text(&mut self, s: &str) { self.0.push(format!("text:{s}")); }
        fn reasoning(&mut self, _: &str) {}
        fn tool_start(&mut self, c: &ToolCall) { self.0.push(format!("start:{}", c.name)); }
        fn tool_end(&mut self, c: &ToolCall, r: &ToolResult) { self.0.push(format!("end:{}:{}", c.name, r.ok)); }
    }

    fn call(name: &str, args: &str) -> Delta {
        Delta::ToolCallChunk { index: 0, id: Some("c".into()), name: Some(name.into()), args: args.into() }
    }

    fn setup(dir: &Path) -> (ToolCtx, Vec<Message>, AgentOpts) {
        std::fs::write(dir.join("a.txt"), "hello\n").unwrap();
        let ctx = ToolCtx { cwd: dir.to_path_buf(), bash_timeout: std::time::Duration::from_secs(5) };
        let msgs = vec![Message::new(Role::System, "sys"), Message::new(Role::User, "go")];
        (ctx, msgs, AgentOpts { max_steps: 5, context_window: 32_768 })
    }

    #[test]
    fn loop_runs_tool_then_answers() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, mut msgs, opts) = setup(dir.path());
        let chat = Script::new(vec![vec![call("read", r#"{"path":"a.txt"}"#)], vec![Delta::Text("done".into())]]);
        let mut ui = Log::default();
        run_turn(&chat, &mut msgs, &ctx, &mut ui, &opts).unwrap();
        assert_eq!(ui.0, vec!["start:read", "end:read:true", "text:done"]);
        let roles: Vec<Role> = msgs.iter().map(|m| m.role).collect();
        assert_eq!(roles, vec![Role::System, Role::User, Role::Assistant, Role::Tool, Role::Assistant]);
        assert_eq!(msgs[2].tool_calls[0].name, "read");
        assert_eq!(msgs[3].tool_call_id.as_deref(), Some("c"));
        assert!(msgs[3].content.contains("hello"));
        assert_eq!(msgs[4].content, "done");
    }

    #[test]
    fn loop_stops_at_max_steps() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, mut msgs, mut opts) = setup(dir.path());
        opts.max_steps = 2;
        let chat = Script::new(vec![vec![call("bash", r#"{"command":"echo $RANDOM"}"#)]]);
        let err = run_turn(&chat, &mut msgs, &ctx, &mut Log::default(), &opts).unwrap_err();
        assert!(matches!(err, AgentError::MaxSteps(2)));
    }

    #[test]
    fn repeat_guard_injects_note() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, mut msgs, opts) = setup(dir.path());
        let same = vec![call("read", r#"{"path":"a.txt"}"#)];
        let chat = Script::new(vec![same.clone(), same.clone(), same, vec![Delta::Text("ok".into())]]);
        run_turn(&chat, &mut msgs, &ctx, &mut Log::default(), &opts).unwrap();
        let notes = msgs.iter().filter(|m| m.role == Role::User && m.content == REPEAT_NOTE).count();
        assert_eq!(notes, 1);
    }

    #[test]
    fn repeat_note_never_splits_tool_results() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, mut msgs, opts) = setup(dir.path());
        let read = call("read", r#"{"path":"a.txt"}"#);
        let two = vec![
            read.clone(),
            Delta::ToolCallChunk { index: 1, id: Some("d".into()), name: Some("bash".into()), args: r#"{"command":"true"}"#.into() },
        ];
        let chat = Script::new(vec![vec![read.clone()], vec![read], two, vec![Delta::Text("ok".into())]]);
        run_turn(&chat, &mut msgs, &ctx, &mut Log::default(), &opts).unwrap();
        for w in msgs.windows(2) {
            assert!(!(w[0].role == Role::User && w[1].role == Role::Tool), "user note between tool results");
        }
        assert!(msgs.iter().any(|m| m.content == REPEAT_NOTE));
    }

    #[test]
    fn call_error_sent_back_as_tool_message() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, mut msgs, opts) = setup(dir.path());
        let chat = Script::new(vec![vec![call("read", r#"{"path": "a"#)], vec![Delta::Text("sorry".into())]]);
        run_turn(&chat, &mut msgs, &ctx, &mut Log::default(), &opts).unwrap();
        let tool = msgs.iter().find(|m| m.role == Role::Tool).unwrap();
        assert!(tool.content.starts_with("arguments were not valid JSON"), "{}", tool.content);
        assert_eq!(msgs[2].tool_calls[0].arguments, json!({}));
    }

    #[test]
    fn budget_applied_before_each_request() {
        let dir = tempfile::tempdir().unwrap();
        let (ctx, mut msgs, mut opts) = setup(dir.path());
        std::fs::write(dir.path().join("big.txt"), "x\n".repeat(5_000)).unwrap();
        opts.context_window = 4_000;
        let chat = Script::new(vec![
            vec![call("read", r#"{"path":"big.txt"}"#)],
            vec![call("read", r#"{"path":"a.txt"}"#)],
            vec![Delta::Text("done".into())],
        ]);
        run_turn(&chat, &mut msgs, &ctx, &mut Log::default(), &opts).unwrap();
        let last_request = chat.seen.borrow().last().unwrap().clone();
        assert!(budget::estimate(&last_request) <= 4_000);
        assert!(last_request.iter().any(|m| m.content == budget::ELIDED));
    }
}
