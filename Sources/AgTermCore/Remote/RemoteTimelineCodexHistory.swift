import Foundation

/// One Codex history row, as agmux's `commands::codex::SessionHistoryItem`.
/// Roles: `user`, `assistant`, `thinking`, `command`, `file`, `tool`.
struct CodexHistoryItem: Equatable {
    var role: String
    var content: String
    var timestamp: String
    var filePath: String?
    var additions: Int?
    var deletions: Int?
    var toolName: String?
    var toolInput: JSONValue?
    var toolError: Bool?

    init(role: String, content: String, timestamp: String, filePath: String? = nil, additions: Int? = nil,
         deletions: Int? = nil, toolName: String? = nil, toolInput: JSONValue? = nil, toolError: Bool? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolError = toolError
    }

    static func tool(_ name: String, _ content: String, _ timestamp: String, _ input: JSONValue, _ isError: Bool) -> Self {
        Self(role: "tool", content: content, timestamp: timestamp, toolName: name, toolInput: input, toolError: isError)
    }

    static func file(_ change: CodexFileChange, _ timestamp: String, editID: String, native: Bool) -> Self {
        Self(role: "file", content: change.diff, timestamp: timestamp, filePath: change.path, additions: change.additions,
             deletions: change.deletions, toolInput: .object(["editId": .string(editID), "nativeEdit": .bool(native)]))
    }
}

struct CodexFileChange: Equatable {
    let path: String
    let diff: String
    let additions: Int
    let deletions: Int
}

/// Codex rollout payload → history rows, from agmux `commands/codex.rs`
/// (`history_tool_item_from_response_item`, patch helpers).
enum CodexHistoryRows {
    static func reasoningSummary(_ payload: JSONValue) -> String? {
        guard let summary = payload["summary"]?.array else { return nil }
        let parts = summary.compactMap { $0.string ?? $0["text"]?.string }.filter { !$0.isBlank }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func outputText(_ output: JSONValue) -> String {
        if let text = output.string { return text }
        if let text = output["output"]?.string { return text }
        if let text = output["text"]?.string { return text }
        if let content = output["content"]?.array {
            let parts = content.map { $0["text"]?.string ?? $0.serdeString }.filter { !$0.isBlank }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return output == .null ? "" : output.serdeString
    }

    static func parseArguments(_ raw: String) -> JSONValue {
        JSONValue.parse(raw) ?? .string(raw)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func toolItem(_ payload: JSONValue, _ ts: String) -> CodexHistoryItem? {
        let status = payload["status"]?.string ?? ""
        let isError = ["failed", "error"].contains(asciiLowercased(status))
        let callID = payload["call_id"]?.string ?? ""
        switch payload["type"]?.string ?? "" {
        case "web_search_call":
            let action = payload["action"] ?? .null
            let query = action["query"]?.string ?? action["queries"]?.array?.lazy.compactMap(\.string).first ?? ""
            let content = [query, action["url"]?.string ?? "", action["pattern"]?.string ?? ""]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            return .tool("WebSearch", content, ts, action, isError)
        case "tool_search_call":
            return .tool("ToolSearch", payload["arguments"]?.serdeString ?? "", ts,
                         .object(["execution": payload["execution"] ?? .null, "arguments": payload["arguments"] ?? .null]), isError)
        case "tool_search_output":
            return .tool("ToolSearch", payload["tools"]?.serdeString ?? "", ts,
                         .object(["execution": payload["execution"] ?? .null]), isError)
        case "image_generation_call":
            return .tool("ImageGeneration", payload["result"]?.string ?? "", ts,
                         .object(["status": .string(status), "revisedPrompt": .string(payload["revised_prompt"]?.string ?? "")]), isError)
        case "function_call":
            let name = payload["name"]?.string ?? ""
            if name.isEmpty || name == "exec_command" { return nil }
            let namespace = payload["namespace"]?.string ?? ""
            // Namespaced collab tools keep the live-event name (collaboration.spawn_agent).
            let displayName = !namespace.isEmpty && !name.containsBytes(".") ? "\(namespace).\(name)" : name
            var input = parseArguments(payload["arguments"]?.string ?? "")
            if case .object(var map) = input {
                if !callID.isEmpty { map["callId"] = .string(callID) }
                if !namespace.isEmpty { map["namespace"] = .string(namespace) }
                input = .object(map)
            } else if !callID.isEmpty {
                input = .object(["value": input, "callId": .string(callID), "namespace": .string(namespace)])
            }
            return .tool(displayName, "", ts, input, false)
        case "function_call_output":
            return .tool("ToolResult", outputText(payload["output"] ?? .null), ts, .object(["callId": .string(callID)]), isError)
        case "local_shell_call":
            let action = payload["action"] ?? .null
            return .tool("LocalShell", action["command"]?.string ?? "", ts, action, isError)
        case "custom_tool_call":
            let name = payload["name"]?.string ?? ""
            if name.isEmpty { return nil }
            return .tool(name, "", ts, .object(["input": payload["input"] ?? .null, "callId": .string(callID)]), isError)
        case "custom_tool_call_output":
            let output = payload["output"] ?? .null
            let content = output.array != nil ? output.serdeString : outputText(output)
            return .tool("ToolResult", content, ts, .object(["callId": .string(callID)]), isError)
        default:
            return nil
        }
    }

    /// `history_native_patch_event`: `patch_apply_end`, or a finished
    /// `item_completed` FileChange normalized to that shape.
    static func nativePatchEvent(_ payload: JSONValue) -> JSONValue? {
        if payload["type"]?.string == "patch_apply_end" { return payload }
        guard payload["type"]?.string == "item_completed", let item = payload["item"],
              item["type"]?.string == "FileChange", let id = item["id"]?.string, !id.isEmpty,
              let status = item["status"]?.string else { return nil }
        let success: Bool
        switch status {
        case "completed": success = true
        case "failed", "declined": success = false
        default: return nil
        }
        return .object(["type": .string("patch_apply_end"), "call_id": .string(id), "success": .bool(success),
                        "changes": item["changes"] ?? .null])
    }

    /// `history_diff_body_lines`: file headers before the first hunk are metadata.
    static func countDiffLines(_ diff: String) -> (additions: Int, deletions: Int) {
        var body = false
        var add = 0
        var del = 0
        for line in rustLines(diff) {
            if line.startsWith("@@") || line.startsWith("*** ") { body = true }
            guard body || !(line.startsWith("+++") || line.startsWith("---")) else { continue }
            if line.startsWith("+") { add += 1 } else if line.startsWith("-") { del += 1 }
        }
        return (add, del)
    }

    /// `file_changes_from_patch_apply_end`.
    static func changesFromPatchApplyEnd(_ payload: JSONValue) -> [CodexFileChange] {
        guard payload["success"]?.bool == true, let changes = payload["changes"]?.object else { return [] }
        return changes.keys.sorted(by: byteLess).compactMap { path in
            guard !path.isBlank, let change = changes[path] else { return nil }
            let unified = change["unified_diff"]?.string ?? ""
            let content = change["content"]?.string ?? ""
            let whole = content.isEmpty ? unified : content
            let (add, del, diff): (Int, Int, String)
            switch change["type"]?.string ?? "update" {
            case "add": (add, del, diff) = (rustLines(whole).count, 0, whole)
            case "delete": (add, del, diff) = (0, rustLines(whole).count, whole)
            default:
                if !unified.isEmpty {
                    let counts = countDiffLines(unified)
                    (add, del, diff) = (counts.additions, counts.deletions, unified)
                } else {
                    (add, del, diff) = (rustLines(content).count, 0, content)
                }
            }
            // No-op success shells keep the badge clean.
            if add == 0 && del == 0 && diff.isBlank { return nil }
            return CodexFileChange(path: path, diff: diff, additions: add, deletions: del)
        }
    }

    /// `parse_apply_patch_history_changes`: one change per `*** … File:` section.
    static func applyPatchChanges(_ patch: String) -> [CodexFileChange] {
        var changes: [CodexFileChange] = []
        var path: String?
        var lines: [String] = []
        func flush() {
            defer { lines = [] }
            guard let current = path else { return }
            path = nil
            let diff = lines.joined(separator: "\n")
            guard !diff.isBlank else { return }
            let counts = countDiffLines(diff)
            changes.append(CodexFileChange(path: current, diff: diff, additions: counts.additions, deletions: counts.deletions))
        }
        let headers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        for line in rustLines(patch.replacingOccurrences(of: "\r\n", with: "\n")) {
            if let header = headers.first(where: { line.startsWith($0) }) {
                flush()
                path = String(decoding: line.utf8.dropFirst(header.utf8.count), as: UTF8.self).rustTrimmed
                lines.append(line)
                continue
            }
            if line.startsWith("*** Move to: ") {
                if path != nil { path = String(decoding: line.utf8.dropFirst(13), as: UTF8.self).rustTrimmed }
                lines.append(line)
                continue
            }
            if line == "*** End Patch" {
                flush()
                break
            }
            if path != nil { lines.append(line) }
        }
        flush()
        return changes
    }
}
