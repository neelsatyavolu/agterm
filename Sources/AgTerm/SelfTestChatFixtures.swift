#if DEBUG
import AgTermCore
import Foundation

/// Transcripts for the Chat self-test, in each agent's real line shapes: a reply with markdown,
/// thinking, folded reads, an edit, commands that pass and fail, a running tool, subagent, web
/// and MCP tools, an image, an interrupted turn, a queued message, unknown lines and unicode.
enum ChatFixtures {
    static let ts = "2026-11-08T12:00:00.000Z"

    static let expectedKinds: [TimelineFeed.Agent: Set<String>] = [
        .claude: ["user", "assistant", "thinking", "tools", "edit", "command", "commands", "tool", "agent", "interrupted"],
        .codex: ["user", "assistant", "thinking", "command", "edit", "agent", "interrupted"],
        .grok: ["user", "assistant", "thinking", "tools", "command", "agent"],
        .agl: ["user", "assistant", "thinking", "edit", "command"],
    ]

    /// agl's session lines (`~/.agl/sessions/<cwd>/<stamp>-<id>.jsonl`).
    static var agl: [String] {
        func line(_ o: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        return [
            line(["type": "session", "id": "6cafcca4", "cwd": "/w/proj", "model": "qwen3-coder-30b", "base_url": "http://127.0.0.1:1234/v1", "ts": 1]),
            line(["type": "user", "text": "Why is the tab dot grey while the agent waits?", "ts": 2]),
            line(["type": "assistant", "text": "", "reasoning": "The dot color is set in TabCardDrawing.", "ts": 3]),
            line(["type": "tool_call", "id": "a1", "name": "read", "arguments": ["path": "Sources/AgTerm/TabCardDrawing.swift"], "ts": 4]),
            line(["type": "tool_result", "id": "a1", "ok": true, "output": "     1\timport AppKit\n     2\tlet dot = Theme.idle", "ts": 5]),
            line(["type": "tool_call", "id": "a2", "name": "edit", "arguments": ["path": "Sources/AgTerm/TabCardDrawing.swift",
                  "old": "let dot = Theme.idle", "new": "let dot = waiting ? Theme.warn : Theme.idle"], "ts": 6]),
            line(["type": "tool_result", "id": "a2", "ok": true, "output": "edited Sources/AgTerm/TabCardDrawing.swift at line 2", "ts": 7]),
            line(["type": "tool_call", "id": "a3", "name": "bash", "arguments": ["command": "swift build"], "ts": 8]),
            line(["type": "tool_result", "id": "a3", "ok": false, "output": "error: cannot find 'waiting' in scope\n[exit code 1]", "ts": 9]),
            line(["type": "assistant", "text": markdown, "reasoning": "", "ts": 10]),
        ]
    }

    static let markdown = """
        ## What changed

        The dot color comes from `TabCardDrawing`, which only knows **idle** and **working**:

        - add a `waiting` state
          - read the approval flag
        1. build
        2. snapshot

        ```swift
        switch tab.agentState {
        case .waiting: dot = Theme.warn
        }
        ```

        | file | lines |
        |---|---|
        | TabCardDrawing.swift | +4 −1 |

        完了 ✅ — שלום — e\u{301} — \(String(repeating: "x", count: 180))
        """

    static func write(to dir: String) -> [TimelineFeed.Agent: URL] {
        let base = URL(fileURLWithPath: dir)
        let files: [TimelineFeed.Agent: URL] = [.claude: base.appendingPathComponent("claude.jsonl"),
                                                .codex: base.appendingPathComponent("codex.jsonl"),
                                                .grok: base.appendingPathComponent("chat_history.jsonl"),
                                                .agl: base.appendingPathComponent("agl.jsonl")]
        try? (claude.joined(separator: "\n") + "\n").write(to: files[.claude]!, atomically: true, encoding: .utf8)
        try? (codex.joined(separator: "\n") + "\n").write(to: files[.codex]!, atomically: true, encoding: .utf8)
        try? (grok.joined(separator: "\n") + "\n").write(to: files[.grok]!, atomically: true, encoding: .utf8)
        try? (agl.joined(separator: "\n") + "\n").write(to: files[.agl]!, atomically: true, encoding: .utf8)
        return files
    }

    static func append(_ url: URL, _ text: String, newline: Bool = true) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((text + (newline ? "\n" : "")).utf8))
    }

    static func writeLarge(_ url: URL, turns: Int) {
        var lines: [String] = []
        for n in 0..<turns {
            lines.append(claudeLine("user", "lu\(n)", "Question \(n): what does line \(n) do?", minute: n))
            lines.append(claudeLine("assistant", "la\(n)", [["type": "text", "text": "Line \(n) sets up `x\(n)`."],
                                                            ["type": "tool_use", "id": "lt\(n)", "name": "Bash", "input": ["command": "echo \(n)"]]], minute: n))
            lines.append(claudeLine("user", "lr\(n)", [["type": "tool_result", "tool_use_id": "lt\(n)", "content": "\(n)"]], minute: n))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Claude Code

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func claudeLine(_ type: String, _ uuid: String, _ content: Any, minute: Int = 0) -> String {
        let time = String(format: "2026-11-08T%02d:%02d:%02d.000Z", 10 + minute / 3600 % 10, minute / 60 % 60, minute % 60)
        return json(["type": type, "uuid": uuid, "timestamp": time,
                     "message": ["content": content, "model": "claude-opus-5-5",
                                 "usage": ["input_tokens": 4_000, "cache_creation_input_tokens": 30_000,
                                           "cache_read_input_tokens": 150_000, "output_tokens": 900]]])
    }

    static func claudeReply(_ uuid: String, _ text: String) -> String {
        claudeLine("assistant", uuid, [["type": "text", "text": text]], minute: 50)
    }

    static func use(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func result(_ id: String, _ content: String, error: Bool = false) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": error]
    }

    static var claude: [String] {
        let longOutput = (1...40).map { "error: line \($0) of a long failure" }.joined(separator: "\n")
        return [
            claudeLine("user", "u1", [["type": "text", "text": "the sidebar dot should turn amber when an agent waits"],
                                      ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBOR"]]], minute: 1),
            claudeLine("assistant", "a1", [["type": "thinking", "thinking": "Find where the dot color is picked."],
                                           use("t1", "Read", ["file_path": "/r/Sources/AgTerm/TabCardDrawing.swift"]),
                                           use("t2", "Grep", ["pattern": "needsApproval"]),
                                           use("t3", "Glob", ["pattern": "**/Theme*.swift"])], minute: 2),
            claudeLine("user", "r1", [result("t1", "41 let dot"), result("t2", "No matches"), result("t3", "Theme.swift")], minute: 2),
            claudeLine("assistant", "a2", [use("t4", "Edit", ["file_path": "/r/Sources/AgTerm/TabCardDrawing.swift",
                                                              "old_string": "dot = tab.isBusy ? Theme.accent : Theme.mute",
                                                              "new_string": (1...16).map { "line \($0) of the new switch" }.joined(separator: "\n")])], minute: 3),
            claudeLine("user", "r2", [result("t4", "ok")], minute: 3),
            claudeLine("assistant", "a3", [use("t5", "Bash", ["command": "swift build"])], minute: 4),
            claudeLine("user", "r3", [result("t5", "Build complete! (3.2s)")], minute: 5),
            claudeLine("assistant", "a3b", [["type": "thinking", "thinking": "", "signature": "sig"],
                                            use("t5b", "Bash", ["command": "git status --short"])], minute: 5),
            claudeLine("user", "r3b", [result("t5b", " M Sources/AgTerm/TabCardDrawing.swift")], minute: 5),
            claudeLine("assistant", "a3c", [use("t5c", "Bash", ["command": "cat > notes/dot.md <<'EOF'\n# Dot colors\n\namber: an agent waits\nEOF"]),
                                            use("t5d", "Bash", ["command": "python3 - <<'EOF'\nfrom pathlib import Path\n"
                                                + "p = Path(\"Sources/AgTerm/Theme.swift\")\nt = p.read_text()\n"
                                                + "t = t.replace('''    static let mute = gray\n''', '''    static let mute = gray\n    static let waiting = amber\n''')\n"
                                                + "p.write_text(t)\nEOF"])], minute: 5),
            claudeLine("user", "r3c", [result("t5c", ""), result("t5d", "")], minute: 5),
            claudeLine("assistant", "a4", [use("t6", "Bash", ["command": "swift test --filter TabCard"])], minute: 6),
            claudeLine("user", "r4", [result("t6", longOutput, error: true)], minute: 6),
            claudeLine("assistant", "a5", [use("t7", "Task", ["description": "Check the other themes", "prompt": "look"]),
                                           use("t8", "WebFetch", ["url": "https://example.com/colors"]),
                                           use("t9", "mcp__figma__get_frame", ["id": "12:3"])], minute: 7),
            claudeLine("user", "r5", [result("t7", "All palettes have a yellow."), result("t8", "page text"),
                                      result("t9", "Failed to call tool", error: true)], minute: 8),
            claudeLine("assistant", "a5b", [use("t11", "Agent", ["description": "Review the dot change", "subagent_type": "code-reviewer",
                                                                 "prompt": "review", "run_in_background": true]),
                                            use("t12", "Workflow", ["script": "export const meta = { name: 'theme-audit', description: 'Audit every theme for a waiting color' }"])], minute: 8),
            claudeLine("user", "r5b", [result("t11", "Async agent launched successfully.\nagentId: a1"),
                                       result("t12", "Workflow launched in background. Task ID: w1")], minute: 8),
            claudeLine("user", "n5", "<task-notification>\n<task-id>a1</task-id>\n<tool-use-id>t11</tool-use-id>\n<status>completed</status>\n"
                       + "<result>No issues. The **amber** dot reads well in Ink and Paper.</result>\n</task-notification>", minute: 9),
            json(["type": "progress", "uuid": "p1", "data": ["unknown": true]]),
            claudeLine("assistant", "a6", [["type": "text", "text": markdown]], minute: 9),
            claudeLine("user", "u2", "[Request interrupted by user]", minute: 10),
            claudeLine("assistant", "a7", [use("t10", "Bash", ["command": "sleep 100"])], minute: 11),
            json(["type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": "and push it after"]),
        ]
    }

    // MARK: Codex

    static var codex: [String] {
        func record(_ type: String, _ payload: [String: Any]) -> String { json(["timestamp": ts, "type": type, "payload": payload]) }
        return [
            record("turn_context", ["model": "gpt-5.5-codex"]),
            record("event_msg", ["type": "user_message", "message": "run the tests and fix the failure"]),
            record("response_item", ["type": "reasoning", "summary": [["type": "summary_text", "text": "Run them first."]]]),
            record("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c1", "arguments": json(["cmd": "swift test"])]),
            record("response_item", ["type": "function_call_output", "call_id": "c1", "output": json(["output": "error: 1 failed", "exit_code": 1])]),
            record("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "p1",
                                     "input": "*** Begin Patch\n*** Update File: Sources/a.swift\n@@\n-let a = 1\n+let a = 2\n*** End Patch"]),
            record("response_item", ["type": "custom_tool_call_output", "call_id": "p1",
                                     "output": json(["output": "Success. Updated the following files:\nM Sources/a.swift", "metadata": ["exit_code": 0]])]),
            record("response_item", ["type": "function_call", "name": "spawn_agent", "namespace": "collaboration", "call_id": "s1",
                                     "arguments": json(["task_name": "check_themes", "agent_type": "explorer", "message": "check"])]),
            record("response_item", ["type": "function_call_output", "call_id": "s1", "output": json(["task_name": "/root/check_themes"])]),
            record("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "completed", "agent_path": "/root/check_themes"]]),
            record("response_item", ["type": "agent_message", "author": "/root/check_themes",
                                     "content": [["type": "input_text", "text": "Message Type: FINAL_ANSWER\nPayload:\nAll themes have a yellow."]]]),
            record("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": markdown]]]),
            record("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c2", "arguments": json(["cmd": "sleep 100"])]),
            record("event_msg", ["type": "turn_aborted", "reason": "interrupted"]),
            record("event_msg", ["type": "user_message", "message": "keep going"]),
            record("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c3", "arguments": json(["cmd": "swift build"])]),
        ]
    }

    // MARK: Grok

    static var grok: [String] {
        func call(_ id: String, _ name: String, _ args: [String: Any]) -> [String: Any] {
            ["id": id, "name": name, "arguments": json(args)]
        }
        func assistant(_ text: String, _ calls: [[String: Any]] = []) -> String {
            var line: [String: Any] = ["type": "assistant", "content": text, "model_id": "grok-4.7-build-fast"]
            if !calls.isEmpty { line["tool_calls"] = calls }
            return json(line)
        }
        return [
            json(["type": "system", "content": "You are Grok."]),
            json(["type": "user", "content": [["type": "text", "text": "<user_query>\nfix the pipeline\n</user_query>"]], "prompt_index": 0]),
            json(["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "Looking at run.sh."]], "status": "completed"]),
            assistant("I'll look.", [call("g1", "read_file", ["target_file": "/w/ops/run.sh"]), call("g2", "grep", ["pattern": "stage"]),
                                     call("g3", "list_dir", ["target_directory": "/w/ops"])]),
            json(["type": "tool_result", "tool_call_id": "g1", "content": "1→#!/bin/bash"]),
            json(["type": "tool_result", "tool_call_id": "g2", "content": "No matches found"]),
            json(["type": "tool_result", "tool_call_id": "g3", "content": "- run.sh"]),
            assistant("", [call("g4", "run_terminal_command", ["command": "ops/run.sh"])]),
            json(["type": "tool_result", "tool_call_id": "g4", "content": "exit: 1\nnode: command not found"]),
            assistant("", [call("g6", "spawn_subagent", ["description": "Find other run scripts", "subagent_type": "explore", "prompt": "look"])]),
            json(["type": "tool_result", "tool_call_id": "g6", "content": "Subagent started in background.\nsubagent_id: sa1"]),
            json(["type": "backend_tool_call", "name": "web_search"]),
            assistant(markdown),
            assistant("", [call("g5", "run_terminal_command", ["command": "npm ci"])]),
        ]
    }
}
#endif
