import Foundation

/// Turns from a Claude Code transcript (`~/.claude/projects/<dir>/<session>.jsonl`): each prompt
/// you sent starts one; the assistant ending its turn, an API error or an interrupt ends it.
public struct SessionTimelineClaude: SessionTimelineFeed {
    public private(set) var turns: [SessionTimelineTurn] = []

    public init() {}

    public mutating func feed(_ line: String) {
        // Most lines are tool calls and results; skip them without parsing.
        guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"")
                || line.contains("\"turn_duration\""),
              let v = JSONValue.parse(line), v["isSidechain"]?.bool != true else { return }
        switch v["type"]?.string {
        case "user": user(v)
        case "assistant": assistant(v)
        case "system" where v["subtype"]?.string == "turn_duration": finish(.done)
        default: break
        }
    }

    private mutating func user(_ v: JSONValue) {
        if v["isCompactSummary"]?.bool == true { return }
        guard let content = v.pointer("/message/content") else { return }
        let text: String
        if let plain = content.string {
            text = plain
        } else if let blocks = content.array {
            // Tool results come back as user lines too; only typed text is a prompt.
            let typed = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            guard !typed.isEmpty else { return }
            text = typed.joined(separator: "\n")
        } else {
            return
        }
        if text.hasPrefix("[Request interrupted by user") { return finish(.cancelled) }
        // Meta lines are command plumbing, except a slash command you typed.
        if v["isMeta"]?.bool == true, !text.hasPrefix("/") { return }
        guard let prompt = ClaudeText.clean(text) else { return }
        finish(.done)
        let id = v["promptId"]?.string ?? v["uuid"]?.string ?? "claude-\(turns.count)"
        // One prompt can span several lines (text, then an image); keep the first.
        if turns.last?.id == id { return }
        turns.append(SessionTimelineTurn(id: id, prompt: prompt, status: .running,
                                         startedAt: v["timestamp"]?.string.map(parseLogTimestamp)))
    }

    private mutating func assistant(_ v: JSONValue) {
        if v["isApiErrorMessage"]?.bool == true { return finish(.failed) }
        switch v.pointer("/message/stop_reason")?.string {
        case "end_turn", "stop_sequence": finish(.done)
        default: break
        }
    }

    /// Ends the latest turn if it's still running.
    private mutating func finish(_ status: SessionTimelineTurn.Status) {
        guard let last = turns.indices.last, turns[last].status == .running else { return }
        turns[last].status = status
    }
}
