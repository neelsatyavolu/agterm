import Foundation

/// Builds the agmux phone timeline for agterm's Claude Code and Codex tabs,
/// ported from agmux `src-tauri/src/remote/timeline.rs` so the phone renders
/// them exactly like agmux's own terminal threads.
public enum RemoteTimeline {
    /// agmux `MAX_TIMELINE_ENTRIES`: phones get only the newest rows.
    public static let maxEntries = 250

    /// agmux's `emptyHint` for a Claude terminal with no session file yet.
    public static let claudeUnlinkedHint = "No session file linked yet — open this chat once on the desktop to attach history."
    /// agmux's `emptyHint` when a Claude transcript yields no rows.
    public static let claudeEmptyHint = "No messages found for this Claude session (history file missing or empty)."
    /// agmux's `emptyHint` when a Codex rollout yields no rows.
    public static let codexEmptyHint = "No Codex history found for this session."

    /// Timeline for a Claude Code transcript (`~/.claude/projects/<dir>/<sessionId>.jsonl`):
    /// complete lines only, the queued/steering overlay applied, newest 250 rows.
    public static func claude(transcript: String) -> [MobileTimelineEntry] {
        capped(ClaudeTimeline.entries(transcript: transcript))
    }

    /// Timeline for a Codex rollout (`~/.codex/sessions/.../rollout-*.jsonl`), newest 250 rows.
    public static func codex(rollout: String) -> [MobileTimelineEntry] {
        capped(CodexTimeline.entries(rollout: rollout))
    }

    /// Timeline for a Grok session's `chat_history.jsonl`, newest 250 rows, only kinds the phone paints.
    public static func grok(chatHistory: String) -> [MobileTimelineEntry] {
        capped(GrokTimeline.entries(chatHistory: chatHistory).filter { isRenderableKind($0.kind) })
    }

    /// Timeline for an agl session file, newest 250 rows.
    public static func agl(session: String) -> [MobileTimelineEntry] {
        capped(AglTimeline.entries(session: session))
    }

    /// The model an agl session is using (`qwen3-coder-30b`).
    public static func modelLabel(agl session: String) -> String? {
        AglTimeline.modelLabel(session: session)
    }

    /// The model of a Grok session's latest reply (`grok-4.7-build-fast`).
    public static func modelLabel(grok chatHistory: String) -> String? {
        GrokTimeline.modelLabel(chatHistory: chatHistory)
    }

    /// The `model` agmux puts on a Claude terminal's thread row: the raw model
    /// id of the latest assistant turn (e.g. `claude-opus-4-5-20251101`). The
    /// phone shortens it for display (`shortModel` → "Opus 4.5").
    public static func modelLabel(claude transcript: String) -> String? {
        ClaudeTimeline.modelLabel(transcript: transcript)
    }

    /// The `model` agmux reports for a Codex session: the last `turn_context`
    /// model (e.g. `gpt-5.3-codex`).
    public static func modelLabel(codex rollout: String) -> String? {
        CodexTimeline.modelLabel(rollout: rollout)
    }

    /// Kinds the phone's `renderEntries` paints.
    public static func isRenderableKind(_ kind: String) -> Bool {
        ["user", "assistant", "thinking", "tool"].contains(kind)
    }

    /// Whether the phone draws anything for `entry`: a renderable kind, and text unless it's a
    /// tool row. The Mac's feed keeps empty thinking blocks for its own chat view.
    public static func showsOnPhone(_ entry: MobileTimelineEntry) -> Bool {
        guard isRenderableKind(entry.kind) else { return false }
        return entry.kind == "tool" || !(entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public struct RenderError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// agmux `assert_timeline_renderable`: ids present, known kinds, text rows
    /// non-blank, tool rows carry a lead or tool name.
    public static func assertRenderable(_ entries: [MobileTimelineEntry]) throws {
        for (i, e) in entries.enumerated() {
            if e.id.isEmpty { throw RenderError(description: "entry[\(i)] missing id") }
            guard isRenderableKind(e.kind) else { throw RenderError(description: "entry[\(i)] unrenderable kind=\(e.kind)") }
            if e.kind == "tool" {
                if (e.lead ?? "").isBlank && (e.toolName ?? "").isBlank {
                    throw RenderError(description: "entry[\(i)] tool missing lead/name")
                }
            } else if (e.text ?? "").isBlank {
                throw RenderError(description: "entry[\(i)] kind=\(e.kind) has empty text")
            }
        }
    }

    /// agmux `cap_entries`: keep the last `max` rows.
    static func capped(_ entries: [MobileTimelineEntry], max: Int = maxEntries) -> [MobileTimelineEntry] {
        entries.count <= max ? entries : Array(entries.suffix(max))
    }
}
