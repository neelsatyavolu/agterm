//! Keeps the conversation inside the model's context window.

use crate::message::{Message, Role};

pub const ELIDED: &str = "[output elided to save context]";

/// Rough token count: chars / 3.5, plus per-message overhead.
pub fn estimate(msgs: &[Message]) -> u32 {
    msgs.iter().map(message_tokens).sum()
}

fn message_tokens(m: &Message) -> u32 {
    let args: usize = m.tool_calls.iter().map(|c| c.name.len() + c.arguments.to_string().len()).sum();
    ((m.content.len() + args) as f32 / 3.5) as u32 + 4
}

/// Replaces the oldest tool results with `ELIDED` until the estimate fits
/// `window_tokens - reserve_tokens`; the newest tool result is cut to fit instead.
/// Never touches the system prompt or user messages.
pub fn fit(msgs: &mut [Message], window_tokens: u32, reserve_tokens: u32) {
    let limit = window_tokens.saturating_sub(reserve_tokens);
    let mut total = estimate(msgs);
    let newest = msgs.iter().rposition(|m| m.role == Role::Tool);
    for (i, m) in msgs.iter_mut().enumerate() {
        if total <= limit {
            return;
        }
        if m.role == Role::Tool && m.content != ELIDED && Some(i) != newest {
            let before = message_tokens(m);
            m.content = ELIDED.to_string();
            total = total - before + message_tokens(m);
        }
    }
    if let Some(i) = newest.filter(|_| total > limit) {
        let others = total - message_tokens(&msgs[i]);
        msgs[i].content = cut_to(&msgs[i].content, limit.saturating_sub(others + 20));
    }
}

/// Keeps the head of `s` within roughly `tokens`.
fn cut_to(s: &str, tokens: u32) -> String {
    let keep = (tokens as f32 * 3.5) as usize;
    if keep < 200 {
        return ELIDED.to_string();
    }
    let head: String = s.chars().take(keep).collect();
    format!("{head}\n[… output cut to fit the context window …]")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn convo() -> Vec<Message> {
        vec![
            Message::new(Role::System, "sys"),
            Message::new(Role::User, "first"),
            Message::new(Role::Assistant, ""),
            Message::tool_result("c0", "a".repeat(3_500)),
            Message::new(Role::Assistant, ""),
            Message::tool_result("c1", "b".repeat(3_500)),
            Message::new(Role::User, "latest"),
        ]
    }

    #[test]
    fn under_budget_untouched() {
        let mut m = convo();
        fit(&mut m, 100_000, 1_000);
        assert_eq!(m, convo());
    }

    #[test]
    fn budget_elides_oldest_tool_results_first() {
        let mut m = convo();
        // ~2000 tokens of tool output; allow ~1300.
        fit(&mut m, 1_500, 200);
        assert_eq!(m[3].content, ELIDED);
        assert_eq!(m[5].content, "b".repeat(3_500));
        assert_eq!(m[0].content, "sys");
        assert_eq!(m[6].content, "latest");
    }

    #[test]
    fn elides_older_results_and_cuts_the_newest_if_needed() {
        let mut m = convo();
        fit(&mut m, 300, 100);
        assert_eq!(m[3].content, ELIDED);
        assert!(m[5].content.starts_with("bbb") && m[5].content.contains("cut to fit"), "{}", m[5].content);
    }

    #[test]
    fn latest_tool_result_is_cut_not_elided() {
        let mut m = vec![
            Message::new(Role::System, "sys"),
            Message::new(Role::User, "read it"),
            Message::new(Role::Assistant, ""),
            Message::tool_result("c0", "line\n".repeat(7_000)),
        ];
        fit(&mut m, 4_000, 1_000);
        assert_ne!(m[3].content, ELIDED);
        assert!(m[3].content.starts_with("line\nline"), "kept the head");
        assert!(m[3].content.contains("cut to fit the context window"));
        assert!(estimate(&m) <= 3_000, "{}", estimate(&m));
    }

    #[test]
    fn estimate_grows_with_content() {
        assert!(estimate(&convo()) > 1_900);
        assert!(estimate(&convo()) < 2_200);
    }
}
