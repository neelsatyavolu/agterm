import Foundation

/// Turns from a Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). Codex brackets
/// each turn with `task_started` and `task_complete` / `turn_aborted`; the first message you sent
/// inside it is the prompt (Codex logs it both as a `user_message` event and a response item).
public struct SessionTimelineCodex: SessionTimelineFeed {
    public private(set) var turns: [SessionTimelineTurn] = []
    /// The turn Codex is in, and whether it has its prompt yet.
    private var openTurn: String?
    private var openTurnHasPrompt = false
    private var openTurnStartedAt: Int?

    public init() {}

    public mutating func feed(_ line: String) {
        guard line.contains("\"event_msg\"") || line.contains("\"role\":\"user\""),
              let v = JSONValue.parse(line), let payload = v["payload"] else { return }
        let ts = v["timestamp"]?.string.map(parseLogTimestamp)
        switch (v["type"]?.string, payload["type"]?.string) {
        case ("event_msg", "task_started"), ("event_msg", "turn_started"):
            finish(.done)
            openTurn = payload["turn_id"]?.string ?? payload.pointer("/turn_attribution/turn_id")?.string ?? "codex-turn-\(turns.count)"
            openTurnHasPrompt = false
            openTurnStartedAt = ts
        case ("event_msg", "user_message"):
            if let text = payload["message"]?.string { prompt(text, ts: ts) }
        case ("response_item", "message") where payload["role"]?.string == "user":
            let text = (payload["content"]?.array ?? []).compactMap { block in
                block["type"]?.string == "input_text" ? block["text"]?.string : nil
            }.joined()
            prompt(text, ts: ts)
        case ("event_msg", "task_complete"), ("event_msg", "turn_complete"):
            finish(.done, turnID: payload["turn_id"]?.string)
        case ("event_msg", "turn_aborted"):
            finish(.cancelled, turnID: payload["turn_id"]?.string)
        case ("event_msg", "error"):
            if let last = turns.indices.last, turns[last].status == .running { turns[last].status = .failed }
        default:
            break
        }
    }

    private mutating func prompt(_ raw: String, ts: Int?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("# AGENTS.md"), !CodexTimeline.isSystemUserMessage(text),
              !text.hasPrefix("<user_instructions>"), !text.hasPrefix("<environment_context>") else { return }
        if let openTurn {
            // A message sent while Codex works steers the same turn.
            guard !openTurnHasPrompt else { return }
            openTurnHasPrompt = true
            turns.append(SessionTimelineTurn(id: openTurn, prompt: text, status: .running, startedAt: openTurnStartedAt ?? ts))
        } else {
            // Rollouts without turn events: the same prompt logged twice in a row is one turn.
            if let last = turns.last, last.prompt == text, last.status == .running { return }
            finish(.done)
            turns.append(SessionTimelineTurn(id: "codex-\(turns.count)", prompt: text, status: .running, startedAt: ts))
        }
    }

    /// Ends `turnID` (or the latest turn) if it's still running.
    private mutating func finish(_ status: SessionTimelineTurn.Status, turnID: String? = nil) {
        if turnID == nil || turnID == openTurn { openTurn = nil }
        // A turn with no prompt of yours (Codex's own setup) has no row to end.
        let index = turnID.map { id in turns.lastIndex { $0.id == id } } ?? turns.indices.last
        guard let index, turns[index].status == .running else { return }
        turns[index].status = status
    }
}
