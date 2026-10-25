import Foundation

/// Tool-row helpers ported from agmux `remote/timeline.rs`: leads, subjects,
/// synthesized edit diffs and result merging shared by Claude and Codex.
enum TimelineTools {
    /// Diffs need more room than a command result; 24k is ~400 lines.
    static let diffBodyLimit = 24_000
    static let resultBodyLimit = 4_000

    /// `tool_base_name`: the part after the last `__` (`mcp__x__Read` → `Read`).
    static func baseName(_ name: String) -> String {
        guard let range = name.range(of: "__", options: .backwards) else { return name }
        return String(name[range.upperBound...])
    }

    static func isAgentTool(_ name: String) -> Bool {
        let base = baseName(name)
        let lower = asciiLowercased(base)
        return ["Task", "Agent", "spawn_subagent", "get_command_or_subagent_output", "dispatch_agent"].contains(base)
            || lower.contains("subagent") || lower == "task" || lower.endsWith("_agent")
    }

    static func humanizeSnake(_ name: String) -> String {
        name.split(separator: "_", omittingEmptySubsequences: true).enumerated().map { index, word in
            guard index == 0, let first = word.unicodeScalars.first else { return String(word) }
            return String(first).uppercased() + String(word.unicodeScalars.dropFirst())
        }.joined(separator: " ")
    }

    private static let readNames: Set = ["read", "read_file", "readfile"]
    private static let editNames: Set = ["edit", "edit_file", "editfile", "multiedit", "multi_edit", "search_replace",
                                         "str_replace", "strreplace", "edit_lines"]
    private static let writeNames: Set = ["write", "write_file", "create_file", "writefile"]
    private static let patchNames: Set = ["apply_patch", "applypatch", "apply_patch_freeform", "applyagentdiff", "patch"]
    private static let shellNames: Set = ["bash", "shell", "run_terminal_command", "run_command", "exec_command", "execute"]
    private static let deleteNames: Set = ["delete", "delete_file", "remove_file"]

    static func lead(_ name: String) -> String {
        let base = baseName(name)
        let lower = asciiLowercased(base)
        if readNames.contains(lower) { return "Read" }
        if editNames.contains(lower) || patchNames.contains(lower) { return "Edited" }
        if writeNames.contains(lower) { return "Wrote" }
        if shellNames.contains(lower) { return "Ran" }
        if ["grep", "glob", "search", "list_dir", "listdir", "glob_file_search", "toolsearch", "search_tool"].contains(lower) {
            return "Searched"
        }
        if deleteNames.contains(lower) { return "Deleted" }
        if ["todowrite", "todo_write", "todo_read"].contains(lower) { return "Todos" }
        if ["task", "agent", "spawn_subagent", "dispatch_agent"].contains(lower) { return "Agent" }
        if ["get_command_or_subagent_output", "await_subagent"].contains(lower) { return "Subagent" }
        if ["webfetch", "web_search", "websearch", "web_fetch"].contains(lower) { return "Web" }
        if lower == "use_tool" { return "Tool" }
        if isAgentTool(name) { return "Agent" }
        if name.startsWith("mcp__") || name.startsWith("mcp_") { return "MCP" }
        if base.contains("_") { return humanizeSnake(base) }
        return base
    }

    static func shortPath(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.utf8.last == 0x2F { trimmed = trimmed.dropLast() }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        switch parts.count {
        case 0: return path
        case 1: return String(parts[0])
        default: return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
        }
    }

    static func subjectDetail(_ name: String, _ input: JSONValue) -> (subject: String?, detail: String?) {
        let path = input.firstPresent(["file_path", "path", "target_file", "filePath"])?.string.map(shortPath)
        let cmd = input.firstPresent(["command", "cmd"])?.string
        let query = input.firstPresent(["pattern", "query", "glob", "description"])?.string
        let prompt = input.firstPresent(["prompt", "description", "subagent_type", "agent"])?.string
        let base = baseName(name)
        let lower = asciiLowercased(base)
        let cut = { (text: String) in timelineTruncate(text, 120) }

        if name.startsWith("mcp__") || name.startsWith("mcp_") {
            let subject: String = query ?? path ?? cmd ?? humanizeSnake(base)
            return (cut(subject), nil)
        }
        if shellNames.contains(lower) {
            return ((cmd ?? input["description"]?.string).map(cut), nil)
        }
        if ["grep", "glob", "search", "glob_file_search", "list_dir", "listdir", "search_tool"].contains(lower) {
            return (query.map(cut) ?? path, path)
        }
        if ["task", "agent", "spawn_subagent", "dispatch_agent", "get_command_or_subagent_output", "await_subagent"].contains(lower) {
            let taskCount = input["task_ids"]?.array.map { "\($0.count) task(s)" }
            return ((prompt ?? taskCount).map(cut), nil)
        }
        if isAgentTool(name) { return (prompt.map(cut), nil) }
        return (path ?? cmd.map(cut) ?? query.map(cut), nil)
    }

    // MARK: Diffs

    static func contentLineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).count
    }

    static func looksLikeDiff(_ text: String) -> Bool {
        rustLines(text).contains { line in
            line.startsWith("@@") || line.startsWith("diff ") || line.startsWith("*** Begin Patch")
                || (line.startsWith("+") && !line.startsWith("+++"))
                || (line.startsWith("-") && !line.startsWith("---"))
        }
    }

    static func countDiffPlusMinus(_ text: String) -> (additions: Int, deletions: Int) {
        var add = 0
        var del = 0
        for line in rustLines(text) {
            if line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@") || line.startsWith("diff ") { continue }
            if line.startsWith("+") { add += 1 } else if line.startsWith("-") { del += 1 }
        }
        return (add, del)
    }

    static func simpleReplaceDiff(_ old: String, _ new: String) -> String {
        let oldN = contentLineCount(old)
        let newN = contentLineCount(new)
        var out = "@@ -\(oldN == 0 ? 0 : 1),\(oldN) +\(newN == 0 ? 0 : 1),\(newN) @@\n"
        if !old.isEmpty { for line in rustLines(old) { out += "-\(line)\n" } }
        if !new.isEmpty { for line in rustLines(new) { out += "+\(line)\n" } }
        return out
    }

    enum FileMutation { case write, edit, patch, delete }

    /// `file_mut_kind`: file-mutating tools get a real diff on the phone.
    static func fileMutation(_ name: String) -> FileMutation? {
        let base = asciiLowercased(baseName(name)).replacingOccurrences(of: "-", with: "_")
        if writeNames.contains(base) { return .write }
        if editNames.contains(base) { return .edit }
        if patchNames.contains(base) { return .patch }
        if deleteNames.contains(base) { return .delete }
        return nil
    }

    /// `edit_body_from_input`: a unified-diff body plus +/- counts from tool input.
    static func editBody(_ name: String, _ input: JSONValue) -> (body: String, additions: Int, deletions: Int)? {
        switch fileMutation(name) {
        case .write:
            let content = input.firstNonEmptyString(["content", "contents", "new_string", "newString", "new"]) ?? ""
            guard !content.isEmpty else { return nil }
            return (simpleReplaceDiff("", content), contentLineCount(content), 0)
        case .delete:
            let old = input.firstNonEmptyString(["old_string", "oldString", "old", "content"]) ?? ""
            guard !old.isEmpty else { return nil }
            return (simpleReplaceDiff(old, ""), 0, contentLineCount(old))
        case .patch:
            let patch = input.firstNonEmptyString(["patch", "diff", "input", "content"]) ?? ""
            guard !patch.isEmpty, looksLikeDiff(patch) else { return nil }
            let counts = countDiffPlusMinus(patch)
            return (patch, counts.additions, counts.deletions)
        case .edit:
            return editToolBody(input)
        case nil:
            return nil
        }
    }

    private static func editToolBody(_ input: JSONValue) -> (body: String, additions: Int, deletions: Int)? {
        if let edits = input["edits"]?.array {
            var body = ""
            var add = 0
            var del = 0
            for edit in edits {
                let old = edit.firstNonEmptyString(["old_string", "oldString", "old"]) ?? ""
                let new = edit.firstNonEmptyString(["new_string", "newString", "new"]) ?? ""
                if old.isEmpty && new.isEmpty { continue }
                add += contentLineCount(new)
                del += contentLineCount(old)
                if !body.isEmpty { body += "\n" }
                body += simpleReplaceDiff(old, new)
            }
            return body.isEmpty ? nil : (body, add, del)
        }
        if let start = input.firstPresent(["start_line", "startLine"])?.int,
           let end = input.firstPresent(["end_line", "endLine"])?.int,
           let new = input.firstNonEmptyString(["new", "new_string", "newString"]) {
            let add = contentLineCount(new)
            let del = end >= start ? end - start + 1 : 0
            var body = "@@ -\(start),\(del) +\(start),\(add) @@\n"
            for line in rustLines(new) { body += "+\(line)\n" }
            return (body, add, del)
        }
        let old = input.firstNonEmptyString(["old_string", "oldString", "old"]) ?? ""
        let new = input.firstNonEmptyString(["new_string", "newString", "new"]) ?? ""
        if old.isEmpty && new.isEmpty { return nil }
        return (simpleReplaceDiff(old, new), contentLineCount(new), contentLineCount(old))
    }

    // MARK: Rows

    /// `fill_tool_from_input`.
    static func filled(_ entry: MobileTimelineEntry, input: JSONValue) -> MobileTimelineEntry {
        var e = entry
        if let edit = editBody(e.toolName ?? "", input) {
            e.body = timelineTruncate(edit.body, diffBodyLimit)
            if edit.additions > 0 { e.additions = edit.additions }
            if edit.deletions > 0 { e.deletions = edit.deletions }
            return e
        }
        // Generic / Codex tools may already carry a unified diff as the body.
        if e.additions == nil, e.deletions == nil, let body = e.body, looksLikeDiff(body) {
            let counts = countDiffPlusMinus(body)
            if counts.additions > 0 { e.additions = counts.additions }
            if counts.deletions > 0 { e.deletions = counts.deletions }
        }
        return e
    }

    /// `apply_tool_result`: attach a result without clobbering a synthesized diff.
    static func applyingResult(_ entry: MobileTimelineEntry, content: String, isError: Bool) -> MobileTimelineEntry {
        var e = entry
        e.status = isError ? "error" : "ok"
        if isError {
            e.additions = nil
            e.deletions = nil
            e.body = timelineTruncate(content, resultBodyLimit)
            return e
        }
        // Cursor file tools send only a path as input; the diff and counts
        // arrive in the result's { status, value } wrapper.
        if fileMutation(e.toolName ?? "") != nil, let result = JSONValue.parse(content) {
            let value = result["value"].flatMap { $0.isObject ? $0 : nil } ?? result
            if let diff = value["diffString"]?.string, !diff.isEmpty {
                let counts = countDiffPlusMinus(diff)
                e.body = timelineTruncate(diff, diffBodyLimit)
                e.additions = max(value["linesAdded"]?.int ?? counts.additions, 0)
                e.deletions = max(value["linesRemoved"]?.int ?? counts.deletions, 0)
                return e
            }
        }
        let hasBody = e.body.map { !$0.isBlank } ?? false
        let keepDiff = (e.additions ?? 0) + (e.deletions ?? 0) > 0
            || e.body.map(looksLikeDiff) == true
            || (["Edited", "Wrote", "Deleted"].contains(e.lead ?? "") && hasBody)
        if keepDiff { return e }
        if !content.isBlank { e.body = timelineTruncate(content, resultBodyLimit) }
        return e
    }

    /// `unwrap_nested_tool`: Grok ACP wraps MCP tools as `use_tool { tool_name, tool_input }`.
    static func unwrapNested(_ name: String, _ input: JSONValue) -> (name: String, input: JSONValue) {
        if asciiLowercased(name) == "use_tool", let inner = input["tool_name"]?.string, !inner.isEmpty {
            return ("mcp__\(inner)", input["tool_input"] ?? .object([:]))
        }
        return (name, input)
    }

    /// `parse_tool_use`: a running tool row from `{name, toolUseId, input}` JSON.
    static func parseToolUse(_ content: String, id: String, ts: Int) -> MobileTimelineEntry? {
        guard let v = JSONValue.parse(content) else { return nil }
        let rawName = v["name"]?.string ?? "tool"
        let toolUseID = v.firstPresent(["toolUseId", "tool_use_id"])?.string
        let (name, input) = unwrapNested(rawName, v["input"] ?? .object([:]))
        let (subject, detail) = subjectDetail(name, input)
        let entry = MobileTimelineEntry(id: id, kind: "tool", lead: lead(name), subject: subject, detail: detail,
                                        status: "running", requestId: toolUseID, toolName: name, ts: ts)
        return filled(entry, input: input)
    }
}
