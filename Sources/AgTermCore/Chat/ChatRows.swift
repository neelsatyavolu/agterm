import Foundation

/// A tool row's state.
public enum ChatToolStatus: String, Equatable, Sendable {
    case running, ok, error

    init(_ status: String?) {
        self = ChatToolStatus(rawValue: status ?? "") ?? .ok
    }
}

/// One tool call as the chat shows it.
public struct ChatTool: Equatable, Sendable {
    public let id: String
    /// The timeline's verb ("Read", "Searched", "Ran", "MCP", ...).
    public let lead: String
    /// The short tool name for a folded line ("Read", "Grep", "Glob", "List").
    public let verb: String
    public let subject: String?
    public let detail: String?
    public let status: ChatToolStatus
    public let body: String?
    public let ts: Int

    init(_ e: MobileTimelineEntry) {
        id = e.id
        lead = e.lead ?? e.toolName ?? "Tool"
        verb = ChatRows.verb(e)
        subject = e.subject
        detail = e.detail
        status = ChatToolStatus(e.status)
        body = e.body
        ts = e.ts
    }

    /// `Read a.swift`, `Grep "x"`.
    public var label: String {
        guard let subject, !subject.isEmpty else { return verb }
        return verb == "Grep" ? "\(verb) \"\(subject)\"" : "\(verb) \(subject)"
    }
}

public struct ChatDiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case added, removed, context }
    public let kind: Kind
    /// The line without its +/- sign.
    public let text: String
}

/// An edit, write or delete with its diff.
public struct ChatEdit: Equatable, Sendable {
    public let id: String
    /// "Edit", "Write" or "Delete".
    public let verb: String
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let status: ChatToolStatus
    public let lines: [ChatDiffLine]

    /// What a collapsed card shows.
    public var preview: ArraySlice<ChatDiffLine> { lines.prefix(ChatRows.editPreviewLines) }
    /// The "… N more lines" count.
    public var hiddenLines: Int { max(0, lines.count - ChatRows.editPreviewLines) }
}

/// A shell command and what it printed.
public struct ChatCommand: Equatable, Sendable {
    public let id: String
    public let command: String
    public let status: ChatToolStatus
    public let output: String?
    /// Until its result arrived (else until the next row started); nil while running or when the transcript has no times.
    public let durationMs: Int?

    public init(id: String, command: String, status: ChatToolStatus, output: String?, durationMs: Int?) {
        self.id = id
        self.command = command
        self.status = status
        self.output = output
        self.durationMs = durationMs
    }

    /// The first non-empty output line, cut short, for a finished command's row.
    public var summary: String? {
        guard let line = outputLines.first(where: { !$0.isBlank }) else { return nil }
        return timelineTruncate(line.rustTrimmed, 80)
    }

    /// The first lines of a failed command's output.
    public var errorLines: [String] { Array(outputLines.prefix(ChatRows.errorPreviewLines)) }
    public var hiddenErrorLines: Int { max(0, outputLines.count - ChatRows.errorPreviewLines) }

    private var outputLines: [String] { output.map(rustLines) ?? [] }
}

/// A subagent or workflow the agent started, and what it came back with.
public struct ChatAgent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case agent, workflow }
    public let id: String
    public let kind: Kind
    /// What it was asked to do ("Review the branch").
    public let title: String?
    /// Which kind of agent ("code-reviewer", "explorer"), or the workflow's name.
    public let type: String?
    public let status: ChatToolStatus
    /// Its final answer, once it finished.
    public let result: String?
    /// From start to finish; nil while it runs or when the transcript has no times.
    public let durationMs: Int?

    /// "Agent" or "Workflow".
    public var label: String { kind == .workflow ? "Workflow" : "Agent" }
}

/// One row of the chat transcript.
public enum ChatRow: Equatable, Sendable {
    case user(id: String, text: String, queued: Bool)
    /// `streaming`: the agent is still working on this reply (draw a cursor after it).
    case assistant(id: String, text: String, streaming: Bool)
    case thinking(id: String, text: String)
    /// Consecutive finished read-like tools, folded into one line.
    case tools(id: String, tools: [ChatTool], durationMs: Int?)
    case edit(ChatEdit)
    case command(ChatCommand)
    /// Consecutive finished commands, folded into one line ("Ran 3 shell commands").
    case commands(id: String, commands: [ChatCommand], durationMs: Int?)
    case tool(ChatTool)
    case agent(ChatAgent)
    case interrupted(id: String)

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _, _), .thinking(let id, _), .tools(let id, _, _), .commands(let id, _, _),
             .interrupted(let id):
            return id
        case .edit(let edit): return edit.id
        case .command(let command): return command.id
        case .tool(let tool): return tool.id
        case .agent(let agent): return agent.id
        }
    }

    /// Whether `id` is this row, or a command folded into it.
    public func holds(_ id: String) -> Bool {
        if case .commands(_, let commands, _) = self, commands.contains(where: { $0.id == id }) { return true }
        return self.id == id
    }

    /// The case name, for logs and tests.
    public var kindName: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .thinking: return "thinking"
        case .tools: return "tools"
        case .edit: return "edit"
        case .command: return "command"
        case .commands: return "commands"
        case .tool: return "tool"
        case .agent: return "agent"
        case .interrupted: return "interrupted"
        }
    }
}

/// Groups timeline entries (Claude, Codex or Grok) into chat rows, so the view only paints them.
public enum ChatRows {
    public static let editPreviewLines = 12
    public static let errorPreviewLines = 8
    public static let screenExcerptLines = 8

    /// `working`: the agent is busy, so a reply at the very end is still streaming.
    public static func build(_ entries: [MobileTimelineEntry], working: Bool) -> [ChatRow] {
        var rows: [ChatRow] = []
        /// The fold being gathered: the entries in it, and the empty thinking seen since its last one.
        var group: (commands: Bool, members: [Int], held: [Int])?

        func closeGroup() {
            guard let open = group, let start = open.members.first, let last = open.members.last else { return }
            let ends = open.members.compactMap { entries[$0].endTs }
            let ms = ends.count == open.members.count
                ? ends.max().flatMap { span(entries[start].ts, $0) }
                : duration(from: entries[start].ts, toEntryAt: last + 1, in: entries)
            let id = "group:" + entries[start].id
            rows.append(open.commands
                ? .commands(id: id, commands: open.members.map { command(entries[$0], at: $0, in: entries) }, durationMs: ms)
                : .tools(id: id, tools: open.members.map { ChatTool(entries[$0]) }, durationMs: ms))
            rows += open.held.map { .thinking(id: entries[$0].id, text: entries[$0].text ?? "") }
            group = nil
        }

        for (index, e) in entries.enumerated() {
            // Thinking the agent kept to itself doesn't split a run of reads or commands.
            if group != nil, e.kind == "thinking", (e.text ?? "").isBlank {
                group?.held.append(index)
                continue
            }
            let edits = e.kind == "tool" && e.lead == "Ran" && e.status == "ok" ? e.shellEdits ?? [] : []
            let foldsAsCommand = isFoldableCommand(e) && (edits.isEmpty || !(e.body ?? "").isBlank)
            if foldsAsCommand || (e.kind == "tool" && isFoldable(e)) {
                if group?.commands != foldsAsCommand {
                    closeGroup()
                    group = (foldsAsCommand, [], [])
                }
                group?.members.append(index)
                group?.held = []
            } else if edits.isEmpty {
                closeGroup()
                if let row = row(e, at: index, in: entries) { rows.append(row) }
            }
            // A command that wrote files shows what it wrote; the command itself only when it printed something.
            if !edits.isEmpty {
                closeGroup()
                rows += edits.enumerated().map { offset, edit in
                    .edit(ChatEdit(id: "\(e.id)#edit\(offset)", verb: edit.verb, path: edit.path, additions: edit.additions,
                                   deletions: edit.deletions, status: .ok, lines: edit.lines))
                }
            }
        }
        closeGroup()

        if working, case let .assistant(id, text, _)? = rows.last {
            rows[rows.count - 1] = .assistant(id: id, text: text, streaming: true)
        }
        return rows
    }

    /// `Read a.swift · Grep "x" · List src`.
    public static func summary(_ tools: [ChatTool]) -> String {
        tools.map(\.label).joined(separator: " · ")
    }

    /// The last non-empty lines of the screen, for a prompt the chat can't parse (a picker or menu).
    public static func screenExcerpt(_ lines: [String], max: Int = screenExcerptLines) -> [String] {
        Array(lines.map(\.rustTrimEnd).filter { !$0.isEmpty }.suffix(max))
    }

    // MARK: Rows

    private static func row(_ e: MobileTimelineEntry, at index: Int, in entries: [MobileTimelineEntry]) -> ChatRow? {
        switch e.kind {
        case "user":
            let text = e.text ?? ""
            if text.startsWith("[Request interrupted by user") { return .interrupted(id: e.id) }
            return .user(id: e.id, text: text, queued: e.state == "queued")
        case "assistant":
            return .assistant(id: e.id, text: e.text ?? "", streaming: false)
        case "thinking":
            return .thinking(id: e.id, text: e.text ?? "")
        case "interrupted":
            return .interrupted(id: e.id)
        case "tool":
            return toolRow(e, at: index, in: entries)
        default:
            return nil
        }
    }

    private static func toolRow(_ e: MobileTimelineEntry, at index: Int, in entries: [MobileTimelineEntry]) -> ChatRow {
        let status = ChatToolStatus(e.status)
        if e.lead == "Ran" { return .command(command(e, at: index, in: entries)) }
        if Subagents.isSpawn(e.toolName ?? "") {
            return .agent(ChatAgent(id: e.id, kind: Subagents.isWorkflow(e.toolName ?? "") ? .workflow : .agent, title: e.subject,
                                    type: e.detail, status: status, result: e.body,
                                    durationMs: status == .running ? nil : e.endTs.flatMap { span(e.ts, $0) }))
        }
        if let verb = editVerbs[e.lead ?? ""], status != .error, let body = e.body, TimelineTools.looksLikeDiff(body) {
            return .edit(ChatEdit(id: e.id, verb: verb, path: e.subject ?? "", additions: e.additions ?? 0,
                                  deletions: e.deletions ?? 0, status: status, lines: diffLines(body)))
        }
        return .tool(ChatTool(e))
    }

    private static func command(_ e: MobileTimelineEntry, at index: Int, in entries: [MobileTimelineEntry]) -> ChatCommand {
        let status = ChatToolStatus(e.status)
        return ChatCommand(id: e.id, command: e.subject ?? "", status: status, output: e.body,
                           durationMs: status == .running ? nil
                               : e.endTs.flatMap { span(e.ts, $0) } ?? duration(from: e.ts, toEntryAt: index + 1, in: entries))
    }

    private static let editVerbs = ["Edited": "Edit", "Wrote": "Write", "Deleted": "Delete"]

    /// Diff lines without file and hunk headers or blank separators.
    static func diffLines(_ body: String) -> [ChatDiffLine] {
        rustLines(body).compactMap { line in
            if line.isEmpty || line.startsWith("@@") || line.startsWith("+++") || line.startsWith("---")
                || line.startsWith("diff ") || line.startsWith("*** ") || line.startsWith("\\ No newline") { return nil }
            let rest = String(line.unicodeScalars.dropFirst())
            if line.startsWith("+") { return ChatDiffLine(kind: .added, text: rest) }
            if line.startsWith("-") { return ChatDiffLine(kind: .removed, text: rest) }
            return ChatDiffLine(kind: .context, text: line.startsWith(" ") ? rest : line)
        }
    }

    // MARK: Folding

    private static let readLikeNames: Set = ["read", "read_file", "readfile", "grep", "glob", "glob_file_search", "ls",
                                             "list_dir", "listdir", "search", "search_tool", "toolsearch"]

    /// A finished read, search or listing: safe to fold away.
    static func isFoldable(_ e: MobileTimelineEntry) -> Bool {
        guard e.status == "ok" else { return false }
        if e.lead == "Read" || e.lead == "Searched" { return true }
        return readLikeNames.contains(asciiLowercased(TimelineTools.baseName(e.toolName ?? "")))
    }

    /// A command that finished without an error.
    static func isFoldableCommand(_ e: MobileTimelineEntry) -> Bool {
        e.kind == "tool" && e.lead == "Ran" && e.status == "ok"
    }

    static func verb(_ e: MobileTimelineEntry) -> String {
        switch asciiLowercased(TimelineTools.baseName(e.toolName ?? "")) {
        case "read", "read_file", "readfile": return "Read"
        case "grep": return "Grep"
        case "glob", "glob_file_search": return "Glob"
        case "ls", "list_dir", "listdir": return "List"
        case "search", "search_tool", "toolsearch": return "Search"
        default: return e.lead ?? e.toolName ?? "Tool"
        }
    }

    /// From `start` to `end`, when both are real times.
    private static func span(_ start: Int, _ end: Int) -> Int? {
        start > 0 && end >= start ? end - start : nil
    }

    /// From `start` to when the entry at `next` began, when both have times.
    private static func duration(from start: Int, toEntryAt next: Int, in entries: [MobileTimelineEntry]) -> Int? {
        guard start > 0, next < entries.count else { return nil }
        let end = entries[next].ts
        return end >= start ? end - start : nil
    }
}
