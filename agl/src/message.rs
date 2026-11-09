//! Chat messages in OpenAI shape.

use serde_json::{Value, json};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::System => "system",
            Role::User => "user",
            Role::Assistant => "assistant",
            Role::Tool => "tool",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Message {
    pub role: Role,
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    pub tool_call_id: Option<String>,
}

impl Message {
    pub fn new(role: Role, content: impl Into<String>) -> Self {
        Self { role, content: content.into(), tool_calls: Vec::new(), tool_call_id: None }
    }

    pub fn tool_result(id: &str, content: impl Into<String>) -> Self {
        Self { tool_call_id: Some(id.to_string()), ..Self::new(Role::Tool, content) }
    }

    /// The request JSON for this message. Tool-call arguments go out as a JSON string.
    pub fn to_json(&self) -> Value {
        let mut v = json!({"role": self.role.as_str(), "content": self.content});
        if !self.tool_calls.is_empty() {
            v["tool_calls"] = self
                .tool_calls
                .iter()
                .map(|c| {
                    json!({"id": c.id, "type": "function",
                           "function": {"name": c.name, "arguments": c.arguments.to_string()}})
                })
                .collect();
        }
        if let Some(id) = &self.tool_call_id {
            v["tool_call_id"] = json!(id);
        }
        v
    }
}

/// Makes a history valid for strict servers: every assistant tool call gets a result
/// (an interrupted one gets `INTERRUPTED`), and adjacent user messages are merged.
pub fn repair(msgs: &mut Vec<Message>) {
    let mut out: Vec<Message> = Vec::with_capacity(msgs.len());
    let mut i = 0;
    while i < msgs.len() {
        let m = &msgs[i];
        i += 1;
        match m.role {
            Role::Assistant if !m.tool_calls.is_empty() => {
                let mut results: Vec<Message> = Vec::new();
                while i < msgs.len() && msgs[i].role == Role::Tool {
                    results.push(msgs[i].clone());
                    i += 1;
                }
                out.push(m.clone());
                // Results go out in call order; unmatched results are dropped.
                for c in &m.tool_calls {
                    let found = results.iter().position(|r| r.tool_call_id.as_deref() == Some(c.id.as_str()));
                    out.push(match found {
                        Some(p) => results.remove(p),
                        None => Message::tool_result(&c.id, INTERRUPTED),
                    });
                }
            }
            // A tool result with no call before it is invalid anywhere else.
            Role::Tool => {}
            Role::User if out.last().is_some_and(|l| l.role == Role::User) => {
                let last = out.last_mut().expect("checked above");
                last.content = format!("{}\n\n{}", last.content, m.content);
            }
            _ => out.push(m.clone()),
        }
    }
    *msgs = out;
}

pub const INTERRUPTED: &str = "[interrupted before this call finished]";

#[cfg(test)]
mod tests {
    use super::*;

    fn asst_calling(ids: &[&str]) -> Message {
        let mut m = Message::new(Role::Assistant, "");
        m.tool_calls = ids
            .iter()
            .map(|id| ToolCall { id: id.to_string(), name: "read".into(), arguments: json!({}) })
            .collect();
        m
    }

    #[test]
    fn repair_adds_missing_results_in_call_order() {
        let mut m = vec![
            Message::new(Role::User, "go"),
            asst_calling(&["a", "b", "c"]),
            Message::tool_result("b", "B"),
            Message::new(Role::User, "next"),
        ];
        repair(&mut m);
        let ids: Vec<_> = m.iter().filter(|x| x.role == Role::Tool).map(|x| x.tool_call_id.clone().unwrap()).collect();
        assert_eq!(ids, vec!["a", "b", "c"]);
        assert_eq!(m[2].content, INTERRUPTED);
        assert_eq!(m[3].content, "B");
        assert_eq!(m[5].content, "next");
    }

    #[test]
    fn repair_merges_adjacent_user_messages() {
        let mut m = vec![Message::new(Role::User, "one"), Message::new(Role::User, "two")];
        repair(&mut m);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].content, "one\n\ntwo");
    }

    #[test]
    fn repair_leaves_valid_history_alone() {
        let mut m = vec![Message::new(Role::User, "go"), asst_calling(&["a"]), Message::tool_result("a", "A")];
        let before = m.clone();
        repair(&mut m);
        assert_eq!(m, before);
    }
}
