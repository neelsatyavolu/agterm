import XCTest
@testable import AgTermCore

/// Grok `chat_history.jsonl` → timeline. Fixture lines are trimmed copies of real
/// Grok 4.7 session files (`~/.grok/sessions/<cwd>/<id>/chat_history.jsonl`).
final class GrokTimelineTests: XCTestCase {
    static func call(_ id: String, _ name: String, _ args: [String: Any]) -> [String: Any] {
        ["id": id, "name": name, "arguments": jsonLine(args)]
    }

    static func assistant(_ text: String, _ calls: [[String: Any]] = [], model: String = "grok-4.7-build-fast") -> String {
        var line: [String: Any] = ["type": "assistant", "content": text, "model_id": model,
                                   "model_fingerprint": "fp_1", "reasoning_effort": "high"]
        if !calls.isEmpty { line["tool_calls"] = calls }
        return jsonLine(line)
    }

    static func result(_ id: String, _ content: String) -> String {
        jsonLine(["type": "tool_result", "tool_call_id": id, "content": content])
    }

    static func user(_ text: String, extra: [String: Any] = [:]) -> String {
        jsonLine(["type": "user", "content": [["type": "text", "text": text]]].merging(extra) { $1 })
    }

    /// A short real-shaped session: preamble, a prompt, reasoning, reads, an edit, a failing command.
    static let session: String = [
        jsonLine(["type": "system", "content": "You are Grok 4.7 released by xAI."]),
        user("<user_info>\nOS Version: macos\nShell: /bin/zsh\n</user_info>"),
        user("<system-reminder>\nThe following skills are available\n</system-reminder>", extra: ["synthetic_reason": "system_reminder"]),
        user("<user_query>\nfix the pipeline\n</user_query>", extra: ["prompt_index": 0]),
        jsonLine(["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "Looking at run.sh."]],
                  "encrypted_content": "x", "status": "completed"]),
        assistant("I'll look.", [call("call-1", "read_file", ["target_file": "/w/ops/run.sh"]),
                                 call("call-2", "grep", ["pattern": "stage", "glob": "*.mjs"]),
                                 call("call-3", "list_dir", ["target_directory": "/w/ops"])]),
        result("call-1", "1→#!/bin/bash\n2→set -e"),
        result("call-2", "<workspace_result workspace_path=\"/w\">\nNo matches found\n</workspace_result>"),
        result("call-3", "- /w/ops/\n  - run.sh"),
        assistant("", [call("call-4", "search_replace", ["file_path": "/w/ops/run.sh", "old_string": "set -e",
                                                         "new_string": "set -euo pipefail\ncd \"$(dirname \"$0\")\""])]),
        result("call-4", "The file /w/ops/run.sh has been updated successfully."),
        assistant("", [call("call-5", "run_terminal_command", ["command": "ops/run.sh", "description": "Run it"])]),
        result("call-5", "exit: 1\nnode: command not found"),
        assistant("Fixed **run.sh**; `node` is missing."),
    ].joined(separator: "\n") + "\n"

    func testSessionBecomesUserThinkingToolsAndReply() throws {
        let e = GrokTimeline.entries(chatHistory: Self.session)
        XCTAssertEqual(e.map(\.kind), ["user", "thinking", "assistant", "tool", "tool", "tool", "tool", "tool", "assistant"])
        XCTAssertEqual(e[0].text, "fix the pipeline")
        XCTAssertEqual(e[1].text, "Looking at run.sh.")
        XCTAssertEqual(e[2].text, "I'll look.")

        XCTAssertEqual(e[3].lead, "Read")
        XCTAssertEqual(e[3].subject, "ops/run.sh")
        XCTAssertEqual(e[3].status, "ok")
        XCTAssertEqual(e[4].lead, "Searched")
        XCTAssertEqual(e[4].subject, "stage")
        XCTAssertEqual(e[5].lead, "Searched")
        XCTAssertEqual(e[5].subject, "w/ops")

        XCTAssertEqual(e[6].lead, "Edited")
        XCTAssertEqual(e[6].additions, 2)
        XCTAssertEqual(e[6].deletions, 1)
        XCTAssertTrue(e[6].body?.contains("+set -euo pipefail") == true)

        XCTAssertEqual(e[7].lead, "Ran")
        XCTAssertEqual(e[7].subject, "ops/run.sh")
        XCTAssertEqual(e[7].status, "error")
        XCTAssertEqual(e[7].body, "node: command not found")
        XCTAssertEqual(e[8].text, "Fixed **run.sh**; `node` is missing.")
        XCTAssertEqual(Set(e.map(\.id)).count, e.count, "ids are unique")
        try RemoteTimeline.assertRenderable(RemoteTimeline.grok(chatHistory: Self.session))
    }

    func testModelLabelIsTheLastAssistantModel() {
        let text = Self.assistant("a", model: "grok-4.6") + "\n" + Self.assistant("b", model: "grok-4.7-build-fast") + "\n"
        XCTAssertEqual(RemoteTimeline.modelLabel(grok: text), "grok-4.7-build-fast")
        XCTAssertNil(RemoteTimeline.modelLabel(grok: ""))
    }

    func testToolWithoutResultIsRunning() {
        let text = Self.assistant("", [Self.call("call-9", "run_terminal_command", ["command": "sleep 60"])]) + "\n"
        let e = GrokTimeline.entries(chatHistory: text)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].status, "running")
        XCTAssertEqual(e[0].subject, "sleep 60")
    }

    func testSuccessfulCommandDropsTheExitLine() {
        let text = [Self.assistant("", [Self.call("c", "run_terminal_command", ["command": "ls"])]),
                    Self.result("c", "exit: 0\nREADME.md\nrun.sh")].joined(separator: "\n") + "\n"
        let e = GrokTimeline.entries(chatHistory: text)
        XCTAssertEqual(e[0].status, "ok")
        XCTAssertEqual(e[0].body, "README.md\nrun.sh")
    }

    func testToolErrorShapes() {
        let errors = ["Error: /w/missing.swift does not exist",
                      "The string to replace was not found in the file, use the read_file tool",
                      "Failed to call take_screenshot: Error: Access denied",
                      "Error calling tool: rg: regex parse error:",
                      "Tool `web_fetch` failed: unsupported content type image/svg+xml",
                      "Hook denied: context-mode: WebFetch redirected."]
        for (i, message) in errors.enumerated() {
            let text = [Self.assistant("", [Self.call("c\(i)", "read_file", ["target_file": "/w/a"])]),
                        Self.result("c\(i)", message)].joined(separator: "\n") + "\n"
            let e = GrokTimeline.entries(chatHistory: text)
            XCTAssertEqual(e[0].status, "error", message)
            XCTAssertEqual(e[0].body, message)
        }
    }

    func testWriteBecomesADiff() {
        let text = [Self.assistant("", [Self.call("w", "write", ["file_path": "ops/run.sh", "content": "#!/bin/bash\nset -e"])]),
                    Self.result("w", "Wrote file successfully to /w/ops/run.sh.")].joined(separator: "\n") + "\n"
        let e = GrokTimeline.entries(chatHistory: text)
        XCTAssertEqual(e[0].lead, "Wrote")
        XCTAssertEqual(e[0].additions, 2)
        XCTAssertTrue(e[0].body?.contains("+#!/bin/bash") == true)
    }

    func testMCPSubagentAndWebTools() {
        let text = [
            Self.assistant("", [
                Self.call("m", "use_tool", ["tool_name": "context-mode__ctx_execute", "tool_input": ["language": "shell", "code": "ls"]]),
                Self.call("s", "spawn_subagent", ["description": "Research the CLI", "prompt": "Find how it works"]),
                Self.call("o", "get_command_or_subagent_output", ["task_ids": ["t1"], "timeout_ms": 60000]),
                Self.call("f", "web_fetch", ["url": "https://example.com/docs"]),
                Self.call("x", "some_new_tool", ["foo": 1]),
            ]),
            jsonLine(["type": "backend_tool_call", "kind": ["tool_type": "web_search",
                                                            "action": ["type": "search", "query": "swift textkit tail"]]]),
        ].joined(separator: "\n") + "\n"
        let e = GrokTimeline.entries(chatHistory: text)
        XCTAssertEqual(e.map { $0.lead ?? "" }, ["MCP", "Agent", "Subagent", "Web", "Some new tool", "Web"])
        XCTAssertEqual(e[0].toolName, "mcp__context-mode__ctx_execute")
        XCTAssertEqual(e[1].subject, "Research the CLI", "the short description, not the whole prompt")
        XCTAssertEqual(e[2].subject, "1 task(s)")
        XCTAssertEqual(e[3].subject, "https://example.com/docs")
        XCTAssertEqual(e[5].subject, "swift textkit tail")
        XCTAssertEqual(e[5].status, "ok")
    }

    func testInterruptAndInterjection() {
        let text = [
            Self.user("<user_query>\nbuild it\n</user_query>", extra: ["prompt_index": 0]),
            Self.user("The user interrupted the previous turn:\n<user_query>\nstop, use make\n</user_query>\nMake sure to complete any unfinished tasks from previous turns.",
                      extra: ["prior_turn_interrupt": "mid_turn_abort", "prompt_index": 1]),
            Self.user("The user sent a message while you were working:\n<user_query>\nwhat's happening\n</user_query>\nMake sure to complete any unfinished tasks from previous turns.",
                      extra: ["synthetic_reason": "interjection"]),
        ].joined(separator: "\n") + "\n"
        let e = GrokTimeline.entries(chatHistory: text)
        XCTAssertEqual(e.map(\.kind), ["user", "interrupted", "user", "user"])
        XCTAssertEqual(e.map { $0.text ?? "" }, ["build it", "", "stop, use make", "what's happening"])
        // The phone timeline only carries kinds the phone paints.
        XCTAssertEqual(RemoteTimeline.grok(chatHistory: text).map(\.kind), ["user", "user", "user"])
    }

    func testSyntheticRemindersAndCompactionAreSkipped() {
        let text = [
            Self.user("<system-reminder>\nBackground task \"t\" completed (exit code: 1).\n</system-reminder>", extra: ["synthetic_reason": "task_completed"]),
            Self.user("This session is being continued from a previous conversation that ran out of context.\n\nSummary: ...",
                      extra: ["synthetic_reason": "compaction_meta"]),
            Self.user("[consult] A message from another agent session", extra: ["synthetic_reason": "stop_hook_feedback"]),
            Self.user("[Image extracted from tool result above]"),
            jsonLine(["type": "reasoning", "id": "r", "summary": [] as [Any], "encrypted_content": "x", "status": "completed"]),
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(GrokTimeline.entries(chatHistory: text), [])
    }

    func testImagesInAUserMessage() {
        let line = jsonLine(["type": "user", "prompt_index": 0, "content": [
            ["type": "text", "text": "<image_files>\nThe following images were provided by the user:\n1. /h/.grok/sessions/x/assets/image-1.jpg\n</image_files>\n\n<user_query>\nthis empty space feels weird\n</user_query>"],
            ["type": "image", "url": "data:image/jpeg;base64,AAAA"],
        ]])
        let e = GrokTimeline.entries(chatHistory: line + "\n")
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].text, "this empty space feels weird\n[Image #1]")
    }

    func testUnicodeMalformedAndUnknownLines() {
        let text = [
            Self.user("<user_query>\n日本語 👩🏽‍💻 שלום e\u{301} \(String(repeating: "x", count: 5000))\n</user_query>"),
            "{not json",
            jsonLine(["type": "brand_new_kind", "content": "?"]),
            Self.assistant("好的 ✅"),
        ].joined(separator: "\n") + "\n"
        let e = GrokTimeline.entries(chatHistory: text)
        XCTAssertEqual(e.map(\.kind), ["user", "assistant"])
        XCTAssertTrue(e[0].text!.hasPrefix("日本語 👩🏽‍💻 שלום e\u{301} xxx"))
        XCTAssertEqual(e[1].text, "好的 ✅")
    }

    func testTruncatedLastLineWaits() {
        let full = Self.assistant("hello")
        let cut = String(full.prefix(full.count / 2))
        XCTAssertEqual(GrokTimeline.entries(chatHistory: Self.user("<user_query>\nhi\n</user_query>") + "\n" + cut).map(\.kind), ["user"])
        XCTAssertEqual(GrokTimeline.entries(chatHistory: ""), [])
    }

    // MARK: Locating the session

    func testLocatesHistoryByCwdAndSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("my proj & co").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("sessions")
        let folder = sessions.appendingPathComponent(cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!)
        let old = folder.appendingPathComponent("11111111-aaaa-4aaa-8aaa-111111111111")
        let new = folder.appendingPathComponent("22222222-bbbb-4bbb-8bbb-222222222222")
        for dir in [old, new] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("chat_history.jsonl"))
        }
        let start = Date()
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-600)],
                                              ofItemAtPath: old.appendingPathComponent("chat_history.jsonl").path)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(5)],
                                              ofItemAtPath: new.appendingPathComponent("chat_history.jsonl").path)

        XCTAssertEqual(GrokSessions.chatHistory(in: sessions, cwd: cwd, sessionID: old.lastPathComponent)?.path,
                       old.appendingPathComponent("chat_history.jsonl").path)
        XCTAssertNil(GrokSessions.chatHistory(in: sessions, cwd: cwd, sessionID: "33333333-cccc-4ccc-8ccc-333333333333"))
        XCTAssertEqual(GrokSessions.latest(in: sessions, cwd: cwd, since: start), new.lastPathComponent)
        XCTAssertEqual(GrokSessions.latest(in: sessions, cwd: cwd, since: start.addingTimeInterval(-3600)), new.lastPathComponent)
        XCTAssertNil(GrokSessions.latest(in: sessions, cwd: cwd, since: start.addingTimeInterval(60)))
        XCTAssertNil(GrokSessions.latest(in: sessions, cwd: "/nowhere", since: .distantPast))
    }
}
