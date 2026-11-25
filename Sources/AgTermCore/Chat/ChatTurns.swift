import Foundation

/// Groups chat rows into turns, the way a chat app shows them: your message, one line that folds
/// everything the agent did ("Worked 1m 12s · read 3 · edited 2 · ran 1"), its answer, then the
/// files the turn changed. The turn still going keeps every step in view, so you can watch it.
public enum ChatTurns {
    public static func fold(_ rows: [ChatRow], stamps: [Int], live: Bool) -> [ChatRow] {
        var out: [ChatRow] = []
        var turn: [Int] = []
        // Messages still waiting in the agent's queue go after everything, outside any turn.
        let queued = rows.indices.filter { if case .user(_, _, true) = rows[$0] { true } else { false } }
        let starts = rows.indices.filter { index in
            if case .user(_, _, false) = rows[index] { return true }
            return false
        }
        var bounds = starts
        if bounds.first != 0, !rows.isEmpty { bounds.insert(0, at: 0) }
        for (number, start) in bounds.enumerated() {
            let end = number + 1 < bounds.count ? bounds[number + 1] : rows.count
            turn = (start..<end).filter { !queued.contains($0) }
            let last = number == bounds.count - 1
            out += last && live ? turn.map { rows[$0] } : folded(turn, rows: rows, stamps: stamps)
        }
        return out + queued.map { rows[$0] }
    }

    /// One finished turn: its message, the worked line, the answer, the changes.
    static func folded(_ turn: [Int], rows: [ChatRow], stamps: [Int]) -> [ChatRow] {
        guard let first = turn.first else { return [] }
        var head: [ChatRow] = []
        var body = turn
        if case .user = rows[first] {
            head.append(rows[first])
            body.removeFirst()
        }
        // The answer is the turn's last reply; replies before it are narration between steps.
        let answer = body.last { if case .assistant = rows[$0] { true } else { false } }
        let ends = body.filter { if case .interrupted = rows[$0] { true } else { false } }
        let steps = body.filter { $0 != answer && !ends.contains($0) }
        guard !steps.isEmpty else { return turn.map { rows[$0] } }

        let id = rows[first].id
        let startTs = stamps[first]
        let endTs = answer.map { stamps[$0] } ?? steps.map { stamps[$0] }.max() ?? 0
        let duration = startTs > 0 && endTs >= startTs ? endTs - startTs : nil
        var out = head + [.worked(id: "worked:" + id, rows: steps.map { rows[$0] }, durationMs: duration)]
        out += answer.map { [rows[$0]] } ?? []
        out += ends.map { rows[$0] }
        let edits = changes(steps.map { rows[$0] })
        if !edits.isEmpty { out.append(.changes(id: "changes:" + id, edits: edits)) }
        return out
    }

    /// A file's row in a changes list opens on its own, apart from the same edit among the steps.
    public static func fileID(_ edit: ChatEdit) -> String { "file:" + edit.id }

    /// Every file the steps changed, once, in the order first touched, with its edits combined.
    static func changes(_ steps: [ChatRow]) -> [ChatEdit] {
        var order: [String] = []
        var byPath: [String: ChatEdit] = [:]
        for case .edit(let edit) in steps where edit.status != .error {
            guard let seen = byPath[edit.path] else {
                order.append(edit.path)
                byPath[edit.path] = edit
                continue
            }
            byPath[edit.path] = ChatEdit(id: seen.id, verb: seen.verb == "Write" || edit.verb == "Delete" ? edit.verb : seen.verb,
                                         path: edit.path, additions: seen.additions + edit.additions,
                                         deletions: seen.deletions + edit.deletions, status: .ok, lines: seen.lines + edit.lines)
        }
        return order.compactMap { byPath[$0] }
    }

    /// What a worked line says after its time: `thought · read 3 · edited 2 · ran 4 · 1 failed`.
    public static func summary(_ steps: [ChatRow]) -> [String] {
        var thought = false, reads = 0, edits = 0, commands = 0, agents = 0, tools = 0, failed = 0
        for row in steps {
            switch row {
            case .thinking: thought = true
            case .tools(_, let list, _): reads += list.count
            case .edit(let edit):
                edits += 1
                if edit.status == .error { failed += 1 }
            case .command(let command):
                commands += 1
                if command.status == .error { failed += 1 }
            case .commands(_, let list, _): commands += list.count
            case .agent(let agent):
                agents += 1
                if agent.status == .error { failed += 1 }
            case .tool(let tool):
                if ["Read", "Grep", "Glob", "List", "Search"].contains(tool.verb) { reads += 1 } else { tools += 1 }
                if tool.status == .error { failed += 1 }
            default: break
            }
        }
        var parts: [String] = []
        if thought { parts.append("thought") }
        if reads > 0 { parts.append("read \(reads)") }
        if edits > 0 { parts.append("edited \(edits)") }
        if commands > 0 { parts.append("ran \(commands)") }
        if agents > 0 { parts.append(agents == 1 ? "1 agent" : "\(agents) agents") }
        if tools > 0 { parts.append(tools == 1 ? "1 tool" : "\(tools) tools") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts
    }
}
