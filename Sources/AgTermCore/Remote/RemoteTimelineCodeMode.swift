import Foundation

/// codex-cli 0.16x "code mode": the model calls one JavaScript `exec` tool whose script calls
/// `tools.exec_command(...)`, `tools.apply_patch(...)`, MCP tools and so on. The rollout records
/// what each of those did as `item_completed` events; these helpers turn them into history rows.
enum CodexCodeMode {
    private static let execCommandCall: NSRegularExpression = {
        // `tools.exec_command({cmd:"…"` with a double- or single-quoted JS string.
        let pattern = #"exec_command\(\s*\{\s*["']?cmd["']?\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#
        // The pattern is a constant; failing to compile it is a programming error.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// The shell commands a script starts, in order, when they are string literals.
    static func shellCommands(_ script: String) -> [String] {
        guard script.containsBytes("exec_command") else { return [] }
        let range = NSRange(script.startIndex..., in: script)
        return execCommandCall.matches(in: script, range: range).compactMap { match in
            Range(match.range(at: 1), in: script).flatMap { jsString(String(script[$0])) }
        }
    }

    private static let applyPatchCall: NSRegularExpression = {
        // `tools.apply_patch("…")`, with a double-, single- or back-quoted JS string.
        let pattern = #"apply_patch\(\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// The patch texts a script passes to `tools.apply_patch`, when they are string literals.
    static func patches(_ script: String) -> [String] {
        guard script.containsBytes("apply_patch") else { return [] }
        let range = NSRange(script.startIndex..., in: script)
        return applyPatchCall.matches(in: script, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: script) else { return nil }
            let literal = String(script[r])
            // A template literal keeps its newlines as typed.
            return literal.hasPrefix("`") ? String(literal.dropFirst().dropLast()) : jsString(literal)
        }
    }

    /// A quoted JS string literal's value (JSON escapes cover what models write).
    static func jsString(_ literal: String) -> String? {
        guard literal.count >= 2 else { return nil }
        var body = String(literal.dropFirst().dropLast())
        if literal.hasPrefix("'") {
            body = body.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return JSONValue.parse("\"\(body)\"")?.string ?? body
    }

    /// What a finished `CommandExecution` record says: the command, its row text
    /// (`$ cmd\noutput\n[exit: N]`) and whether it failed.
    static func command(_ item: JSONValue) -> (cmd: String, content: String, failed: Bool)? {
        let argv = item["command"]?.array?.compactMap(\.string) ?? []
        let shell = argv.count >= 3 && ["-lc", "-c"].contains(argv[argv.count - 2])
        guard let cmd = shell ? argv.last : (argv.isEmpty ? item["command"]?.string : argv.joined(separator: " ")),
              !cmd.isEmpty else { return nil }
        let exitCode = item["exit_code"]?.int
        let output = (item["aggregated_output"]?.string ?? "").rustTrimmed
        let failed = (exitCode ?? 0) != 0 || ["failed", "declined"].contains(item["status"]?.string ?? "")
        var content = "$ \(cmd)"
        if !output.isEmpty { content += "\n\(output)" }
        if let exitCode { content += "\n[exit: \(exitCode)]" }
        return (cmd, content, failed)
    }

    /// A row for another native record, or nil for plumbing (sub-agent bookkeeping, waits)
    /// and kinds shown elsewhere.
    static func toolItem(_ item: JSONValue, _ ts: String) -> CodexHistoryItem? {
        let failed = ["failed", "error", "declined"].contains(item["status"]?.string ?? "")
        switch item["type"]?.string {
        case "McpToolCall":
            let server = item["server"]?.string ?? "mcp"
            let tool = item["tool"]?.string ?? "tool"
            let input = item["arguments"].flatMap { $0.isObject ? $0 : nil } ?? .object([:])
            let error = item.pointer("/error/message")?.string ?? item["error"]?.string
            let result = error ?? item["result"].map(resultText) ?? ""
            return .tool("mcp__\(server)__\(tool)", result, ts, input, failed || error != nil)
        case "Extension" where item["kind"]?.string == "web.search":
            let action = item["action"] ?? .null
            let query = item["query"]?.string ?? action["query"]?.string
                ?? action["queries"]?.array?.lazy.compactMap(\.string).first ?? ""
            return .tool("WebSearch", query, ts, .object(["query": .string(query)]), failed)
        case "ImageView":
            let path = (item["path"]?.string ?? "").replacingOccurrences(of: "file://", with: "")
            return .tool("view_image", "", ts, .object(["path": .string(path)]), failed)
        default:
            return nil
        }
    }

    /// An MCP result's text blocks.
    private static func resultText(_ result: JSONValue) -> String {
        if let blocks = result["content"]?.array {
            return blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        }
        return result == .null ? "" : (result.string ?? result.serdeString)
    }

    /// The row for a script that did nothing the rollout records natively: an MCP call named
    /// after its tool (older codex-cli), nothing for `write_stdin` polls, else `Script`.
    static func scriptItem(_ script: String, _ output: (text: String, failed: Bool, running: Bool), _ ts: String) -> CodexHistoryItem? {
        let called = toolCalls(script)
        if !called.isEmpty, called.allSatisfy({ $0 == "write_stdin" || $0 == "exec_command" }) { return nil }
        if let mcp = called.first(where: { $0.hasPrefix("mcp__") }) {
            return .tool(mcp, output.text, ts, .object([:]), output.failed)
        }
        return .tool("Script", output.text, ts, .object([:]), output.failed)
    }

    private static let toolCall: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"tools\.([A-Za-z0-9_]+)\s*\("#)
    }()

    /// The `tools.<name>(` a script calls, in order.
    static func toolCalls(_ script: String) -> [String] {
        let range = NSRange(script.startIndex..., in: script)
        return toolCall.matches(in: script, range: range).compactMap { match in
            Range(match.range(at: 1), in: script).map { String(script[$0]) }
        }
    }

    /// `{"exit_code":1,"output":"…"}`, what `exec_command` returns inside a script's output.
    static func commandResult(_ text: String) -> (exitCode: Int, output: String)? {
        guard let start = text.firstIndex(of: "{"), let json = JSONValue.parse(text[start...]),
              let code = json["exit_code"]?.int else { return nil }
        return (code, (json["output"]?.string ?? "").rustTrimmed)
    }

    /// An `exec` call's output without its `Script completed / Wall time` header; `running` when
    /// the script yielded and a later `wait` will finish it.
    static func scriptOutput(_ output: JSONValue) -> (text: String, failed: Bool, running: Bool) {
        let parts = output.array?.compactMap { $0["text"]?.string } ?? [output.string ?? ""]
        let header = parts.first ?? ""
        let running = header.startsWith("Script running")
        let failed = header.startsWith("Script failed") || header.startsWith("Script error") || header.startsWith("aborted")
        var body = parts.dropFirst().joined(separator: "\n")
        if parts.count == 1, let range = header.range(of: "Output:\n") { body = String(header[range.upperBound...]) }
        return (body.rustTrimmed, failed, running)
    }
}
