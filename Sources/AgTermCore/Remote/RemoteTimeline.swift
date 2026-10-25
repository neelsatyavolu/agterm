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
