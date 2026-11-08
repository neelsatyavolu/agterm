import Foundation

/// An agent that can take over another agent's conversation: started interactively with a
/// first message that points it at the brief.
public enum HandoffTarget: String, CaseIterable, Sendable {
    case claude, codex, grok, gemini

    public var title: String { AgentKind.named(rawValue)?.title ?? rawValue }

    /// What to type at a new tab's prompt. Plain command names, like New Agent Tab, so your
    /// aliases and agterm's wrappers (MCP servers, Settings → Permissions) apply.
    public func commandLine(prompt: String) -> String {
        let escaped = ShellEscape.path(prompt)
        switch self {
        case .gemini: return "gemini -i " + escaped
        default: return rawValue + " " + escaped
        }
    }
}

/// The brief a new agent reads to continue another agent's work.
public enum Handoff {
    /// The first message the new agent gets. One line, so it types cleanly at a shell prompt.
    public static func prompt(briefPath: String, fromAgent: String) -> String {
        "You're taking over a task from \(title(fromAgent)). Read \(briefPath) for the conversation so far, "
            + "check the current state of the files, then continue with the latest request. Don't redo finished steps."
    }

    /// The conversation as markdown. Over `maxCharacters`, keeps the first request (the task)
    /// and as many of the latest rows as fit.
    public static func brief(entries: [MobileTimelineEntry], fromAgent: String, cwd: String, branch: String?,
                             maxCharacters: Int = 40_000) -> String {
        let head = header(fromAgent: fromAgent, cwd: cwd, branch: branch) + "## Conversation\n\n"
        let blocks = entries.compactMap(block)
        let budget = max(0, maxCharacters - head.count)
        let all = blocks.joined(separator: "\n")
        if all.count <= budget { return head + all }

        let firstUser = entries.first { $0.kind == "user" }.flatMap(block)
        let first = firstUser.map { cut($0, to: budget / 3) } ?? ""
        let firstIndex = firstUser.flatMap { f in blocks.firstIndex(of: f) }
        let markerRoom = 60
        var room = budget - first.count - markerRoom
        var recent: [String] = []
        for (index, block) in blocks.enumerated().reversed() where index != firstIndex {
            guard room > 0 else { break }
            let piece = block.count + 1 <= room ? block : cut(block, to: room - 1)
            guard piece.count + 1 <= room, !piece.isEmpty else { break }
            recent.insert(piece, at: 0)
            room -= piece.count + 1
            if piece.count < block.count { break }
        }
        let left = blocks.count - recent.count - (firstIndex == nil ? 0 : 1)
        let marker = left > 0 ? "\n_… \(left) earlier steps left out …_\n\n" : "\n"
        return String((head + first + marker + recent.joined(separator: "\n")).prefix(maxCharacters))
    }

    /// For agents without a readable transcript: the end of the terminal, as text.
    public static func brief(screen text: String, fromAgent: String, cwd: String, branch: String?,
                             maxCharacters: Int) -> String {
        let head = header(fromAgent: fromAgent, cwd: cwd, branch: branch)
            + "## The end of the terminal\n\nThe agent's transcript couldn't be read, so this is what its tab showed.\n\n```\n"
        let tail = "\n```\n"
        let room = max(0, maxCharacters - head.count - tail.count)
        var body = text.count <= room ? text : String(text.suffix(room))
        // Start on a whole line.
        if body.count < text.count, let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
        return head + body + tail
    }

    // MARK: Pieces

    private static func title(_ agent: String) -> String { AgentKind.named(agent)?.title ?? agent }

    private static func header(fromAgent: String, cwd: String, branch: String?) -> String {
        var lines = ["# Handoff from \(title(fromAgent))", "",
                     "Another agent was working on this task. Its conversation is below; the files may have changed since.",
                     "", "- Folder: \(cwd)"]
        if let branch, !branch.isEmpty { lines.append("- Branch: \(branch)") }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// One row as markdown, or nil for rows the new agent doesn't need (thinking, empty).
    private static func block(_ entry: MobileTimelineEntry) -> String? {
        let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch entry.kind {
        case "user":
            return text.isEmpty ? nil : "### User\n\n\(text)\n"
        case "assistant":
            return text.isEmpty ? nil : "### \(entry.state == "queued" ? "Queued" : "Agent")\n\n\(text)\n"
        case "tool":
            return toolLine(entry)
        default:
            return nil
        }
    }

    private static func toolLine(_ entry: MobileTimelineEntry) -> String? {
        let lead = entry.lead ?? entry.toolName ?? "Used"
        let subject = (entry.subject ?? entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var line = "- " + lead
        if !subject.isEmpty {
            line += lead == "Ran" ? " `\(subject.replacingOccurrences(of: "`", with: "'"))`" : " " + subject
        }
        if let a = entry.additions, let d = entry.deletions, a + d > 0 { line += " (+\(a) −\(d))" }
        if entry.status == "error" { line += " — failed" }
        return line
    }

    /// Cuts the middle out of `text` so it fits `limit` characters.
    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n[… cut …]\n"
        guard limit > marker.count + 2 else { return String(text.prefix(max(0, limit))) }
        let keep = limit - marker.count
        return String(text.prefix(keep / 2)) + marker + String(text.suffix(keep - keep / 2))
    }
}
