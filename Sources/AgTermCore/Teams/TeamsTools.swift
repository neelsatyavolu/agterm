import Foundation

/// Which bucket a tool call falls into. Provider tool names are normalised into
/// this fixed taxonomy so one chart can span Claude, Codex and Grok.
public enum ToolKind: Equatable, Sendable {
    case bash, edit, read, search, web, agent, mcp, other
}

/// Per-event tool activity. Every field is a plain counter.
///
/// `measured` is a separate denominator from the call counts: Claude flags every
/// result with `is_error`, but Codex reports outcomes only for patches. The
/// error rate is `errors / measured`, never `errors / calls`.
/// `filesChanged` counts file-change operations, not distinct files, so it stays
/// true when buckets are summed.
public struct ToolTally: Equatable, Sendable {
    public var bash = 0
    public var edit = 0
    public var read = 0
    public var search = 0
    public var web = 0
    public var agent = 0
    public var mcp = 0
    public var other = 0
    /// Tool calls that failed, among those whose outcome was observable.
    public var errors = 0
    /// Tool calls whose success or failure the log actually reports.
    public var measured = 0
    /// File-change operations (an edit, a write, one file in a patch).
    public var filesChanged = 0
    public var linesAdded = 0
    public var linesRemoved = 0

    public init(bash: Int = 0, edit: Int = 0, read: Int = 0, search: Int = 0, web: Int = 0, agent: Int = 0,
                mcp: Int = 0, other: Int = 0, errors: Int = 0, measured: Int = 0, filesChanged: Int = 0,
                linesAdded: Int = 0, linesRemoved: Int = 0) {
        (self.bash, self.edit, self.read, self.search, self.web, self.agent, self.mcp, self.other) =
            (bash, edit, read, search, web, agent, mcp, other)
        (self.errors, self.measured, self.filesChanged, self.linesAdded, self.linesRemoved) =
            (errors, measured, filesChanged, linesAdded, linesRemoved)
    }

    /// Total classified tool calls (excludes the error and line counters).
    public var calls: Int { bash + edit + read + search + web + agent + mcp + other }

    public var isEmpty: Bool { self == ToolTally() }

    /// Every counter summed with `other`'s.
    public func adding(_ o: ToolTally) -> ToolTally {
        ToolTally(bash: bash + o.bash, edit: edit + o.edit, read: read + o.read, search: search + o.search,
                  web: web + o.web, agent: agent + o.agent, mcp: mcp + o.mcp, other: other + o.other,
                  errors: errors + o.errors, measured: measured + o.measured, filesChanged: filesChanged + o.filesChanged,
                  linesAdded: linesAdded + o.linesAdded, linesRemoved: linesRemoved + o.linesRemoved)
    }

    /// This tally with one more call of `kind`.
    public func counting(_ kind: ToolKind) -> ToolTally {
        var t = self
        switch kind {
        case .bash: t.bash += 1
        case .edit: t.edit += 1
        case .read: t.read += 1
        case .search: t.search += 1
        case .web: t.web += 1
        case .agent: t.agent += 1
        case .mcp: t.mcp += 1
        case .other: t.other += 1
        }
        return t
    }
}

/// Tool-name classification and edit-size measurement. Only names, statuses and
/// line counts are read; edit text never leaves these functions.
public enum TeamsTools {
    private static let kinds: [ToolKind: Set<String>] = [
        .bash: ["bash", "bashoutput", "killshell", "exec", "exec_command", "local_shell_call", "shell",
                "run_terminal_command", "run_command", "terminal", "execute"],
        .edit: ["edit", "write", "multiedit", "notebookedit", "apply_patch", "search_replace", "str_replace",
                "create_file", "edit_file", "write_file"],
        .read: ["read", "read_file", "view", "view_file", "notebookread"],
        .search: ["grep", "glob", "list_dir", "ls", "find", "search_tool", "codebase_search", "file_search", "grep_search"],
        .web: ["webfetch", "websearch", "web_fetch", "web_search", "browser", "fetch", "web"],
        .agent: ["task", "agent", "spawn_agent", "spawn_subagent", "wait_agent", "list_agents", "interrupt_agent",
                 "send_message", "followup_task", "subagent"],
    ]

    /// Maps Claude (`Bash`, `Edit`), Codex (`exec_command`, `apply_patch`) and Grok
    /// (`run_terminal_command`, `search_replace`) names onto the taxonomy. Unknown
    /// names land in `.other` so the kinds always re-sum to the call total.
    public static func classify(_ name: String) -> ToolKind {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("mcp__") { return .mcp }
        let lower = asciiLowercased(trimmed)
        return kinds.first { $0.value.contains(lower) }?.key ?? .other
    }

    /// Line count of a text block, as Rust's `str::lines`: empty text is zero
    /// lines and a trailing newline does not start another.
    public static func lineCount(_ text: String) -> Int {
        rustLines(text).count
    }

    /// Added and removed line counts from a unified diff; `+++`/`---` headers excluded.
    public static func unifiedDiffLines(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in rustLines(diff) {
            let bytes = Array(line.utf8.prefix(3))
            if bytes == Array("+++".utf8) || bytes == Array("---".utf8) { continue }
            switch bytes.first {
            case UInt8(ascii: "+"): added += 1
            case UInt8(ascii: "-"): removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    /// Line delta of an old-to-new string replacement (Claude `Edit`, Grok `search_replace`).
    public static func replacementLines(old: String, new: String) -> (added: Int, removed: Int) {
        (lineCount(new), lineCount(old))
    }
}
