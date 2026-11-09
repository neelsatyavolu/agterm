import XCTest
@testable import AgTermCore

/// Codex rollouts → chat rows, per situation in the chat spec. Real `codex exec` rollouts are read
/// from `AGTERM_CODEX_ROLLOUTS` (default: the tester's scratch folder) and skipped when absent.
final class ChatCodexScenarioTests: XCTestCase {
    static let rolloutDir = ProcessInfo.processInfo.environment["AGTERM_CODEX_ROLLOUTS"]
        ?? "/private/tmp/claude-503/agterm-chat-tests/rollouts"

    func realRollout(_ name: String) throws -> String {
        let path = Self.rolloutDir + "/\(name).jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw XCTSkip("no rollout at \(path)") }
        return text
    }

    func rows(_ rollout: String, working: Bool = false) -> [ChatRow] {
        var feed = TimelineFeed(agent: .codex)
        feed.feed(chunk: Data(rollout.utf8))
        return ChatRows.build(feed.entries, working: working)
    }

    func dump(_ rows: [ChatRow]) -> String {
        rows.map { row -> String in
            switch row {
            case let .user(_, text, queued): return "user\(queued ? "(queued)" : ""): \(text.prefix(60))"
            case let .assistant(_, text, s): return "assistant\(s ? "(streaming)" : ""): \(text.prefix(60))"
            case let .thinking(_, text): return "thinking: \(text.prefix(60))"
            case let .tools(_, tools, _): return "tools: \(ChatRows.summary(tools))"
            case let .edit(e): return "edit: \(e.verb) \(e.path) +\(e.additions) -\(e.deletions) lines=\(e.lines.count)"
            case let .command(c): return "command[\(c.status)]: \(c.command) | \(c.summary ?? "-")"
            case let .tool(t): return "tool[\(t.status)]: \(t.lead) \(t.subject ?? "") | \(t.body?.prefix(60) ?? "-")"
            case let .agent(a): return "agent[\(a.status)]: \(a.title ?? "") | \(a.result?.prefix(60) ?? "-")"
            case .interrupted: return "interrupted"
            }
        }.joined(separator: "\n")
    }

    // MARK: Records in the shapes codex-cli 0.167 writes

    let ts = "2026-11-08T12:00:00.000Z"

    func record(_ type: String, _ payload: [String: Any], at time: String? = nil) -> String {
        jsonLine(["timestamp": time ?? ts, "type": type, "payload": payload])
    }

    func userMessage(_ text: String) -> [String] {
        [record("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]),
         record("event_msg", ["type": "item_completed", "item": ["type": "UserMessage", "id": UUID().uuidString,
                                                                "content": [["type": "text", "text": text]]]])]
    }

    func assistant(_ text: String, phase: String = "final_answer") -> [String] {
        [record("event_msg", ["type": "item_completed", "item": ["type": "AgentMessage", "id": "m", "content": [["type": "Text", "text": text]], "phase": phase]]),
         record("response_item", ["type": "message", "role": "assistant", "phase": phase,
                                  "content": [["type": "output_text", "text": text]]])]
    }

    /// A code-mode `exec` call running one shell command, as 0.167 writes it (no `exec_command` function_call).
    func execCommand(_ cmd: String, callID: String, output: String?, exit: Int?, at time: String? = nil, endTime: String? = nil) -> [String] {
        let escaped = cmd.replacingOccurrences(of: "\"", with: "\\\"")
        var lines = [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": callID, "name": "exec",
                                              "input": "text(await tools.exec_command({cmd:\"\(escaped)\",max_output_tokens:1000}));\n"], at: time)]
        guard let output, let exit else { return lines }
        lines.append(record("event_msg", ["type": "item_completed", "item": [
            "type": "CommandExecution", "id": "exec-\(callID)", "command": ["/bin/zsh", "-lc", cmd],
            "status": exit == 0 ? "completed" : "failed", "aggregated_output": output, "exit_code": exit]], at: endTime))
        lines.append(record("response_item", ["type": "custom_tool_call_output", "call_id": callID, "output": [
            ["type": "input_text", "text": "Script completed\nWall time 0.7 seconds\nOutput:\n"],
            ["type": "input_text", "text": jsonLine(["exit_code": exit, "output": output])]]], at: endTime))
        return lines
    }

    func rollout(_ lines: [[String]]) -> String {
        ([record("turn_context", ["model": "gpt-6-astra"])] + lines.flatMap { $0 }).joined(separator: "\n") + "\n"
    }

    // MARK: Real rollouts

    func testRealPlainMarkdownReply() throws {
        let rows = rows(try realRollout("plain"))
        print("plain:\n" + dump(rows))
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant"], dump(rows))
        guard case let .assistant(_, text, _)? = rows.last else { return XCTFail(dump(rows)) }
        let lines = ChatText.lines(text)
        XCTAssertTrue(lines.contains { if case .heading = $0 { return true }; return false }, "\(lines)")
        XCTAssertEqual(lines.filter { if case .bullet = $0 { return true }; return false }.count, 5, "\(lines)")
        XCTAssertTrue(lines.contains(.code([#"message = "Three backticks: ```""#])), "\(lines)")
        XCTAssertTrue(text.contains("日本語") && text.contains("🎉"))
    }

    func testRealShellCommandsOkAndFailing() throws {
        let rows = rows(try realRollout("shell"))
        print("shell:\n" + dump(rows))
        let commands = rows.compactMap { row -> ChatCommand? in if case let .command(c) = row { return c }; return nil }
        XCTAssertEqual(commands.map(\.command), ["echo hello-agterm", "ls does_not_exist_dir", "seq 1 300"], dump(rows))
        XCTAssertEqual(commands.map(\.status), [.ok, .error, .ok], dump(rows))
        XCTAssertEqual(commands.first?.summary, "hello-agterm")
        XCTAssertFalse(rows.contains { if case let .tool(t) = $0 { return t.lead == "exec" || t.verb == "exec" }; return false },
                       "code-mode exec wrappers should not show as raw JS tool rows:\n" + dump(rows))
    }

    func testRealApplyPatchEdits() throws {
        let rows = rows(try realRollout("patch"))
        print("patch:\n" + dump(rows))
        let edits = rows.compactMap { row -> ChatEdit? in if case let .edit(e) = row { return e }; return nil }
        XCTAssertEqual(edits.count, 2, dump(rows))
        XCTAssertEqual(edits.map(\.path).map { ($0 as NSString).lastPathComponent }, ["notes.txt", "notes.txt"])
        XCTAssertEqual(edits.last?.lines.filter { $0.kind != .context }.map(\.text), ["beta", "BETA"])
        XCTAssertEqual(edits.first?.additions, 3)
        XCTAssertFalse(rows.contains { if case .tool = $0 { return true }; return false },
                       "the exec wrapper of apply_patch should not add a tool row:\n" + dump(rows))
    }

    func testRealRolloutsFeedTheSameInAnyChunking() throws {
        for name in ["plain", "shell", "patch"] {
            let text = try realRollout(name)
            let whole = rows(text)
            var feed = TimelineFeed(agent: .codex)
            let data = Data(text.utf8)
            var pending = Data()
            var start = 0
            while start < data.count {
                pending += data[start..<min(start + 997, data.count)]
                pending = pending.dropFirst(feed.feed(chunk: pending))
                start += 997
            }
            XCTAssertEqual(ChatRows.build(feed.entries, working: false), whole, name)
            XCTAssertEqual(feed.model, "gpt-6-astra", name)
        }
    }

    /// The real codex-cli 0.167 start-up picker ("Hooks need review"), captured from a pty: Chat shows it
    /// as a card with one button per numbered answer.
    func testRealHooksPickerScreenIsAPromptCard() throws {
        let path = "/private/tmp/claude-503/agterm-chat-tests/codex-approve/picker-screen.json"
        guard let data = FileManager.default.contents(atPath: path),
              let lines = try JSONSerialization.jsonObject(with: data) as? [String] else { throw XCTSkip("no screen at \(path)") }
        let prompt = try XCTUnwrap(PermissionPrompt.read(lines), lines.joined(separator: "\n"))
        XCTAssertEqual(prompt.question, "Hooks need review")
        XCTAssertEqual(prompt.choices.map(\.key), ["1", "2", "3"])
    }

    // MARK: Synthetic situations (0.167 shapes)

    func testCommandsFromCodeModeExec() {
        let rows = rows(rollout([userMessage("run it"),
                                 execCommand("echo hi", callID: "c1", output: "hi\n", exit: 0),
                                 execCommand("false", callID: "c2", output: "boom\n", exit: 1),
                                 assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "command", "command", "assistant"], dump(rows))
    }

    func testCommandStillRunningShowsRunning() {
        let rows = rows(rollout([userMessage("run it"), execCommand("sleep 100", callID: "c1", output: nil, exit: nil)]), working: true)
        guard case let .command(c)? = rows.last else { return XCTFail(dump(rows)) }
        XCTAssertEqual(c.status, .running)
        XCTAssertEqual(c.command, "sleep 100")
    }

    func testInterruptedTurn() {
        let rows = rows(rollout([userMessage("run it"), execCommand("sleep 100", callID: "c1", output: nil, exit: nil),
                                 [record("event_msg", ["type": "turn_aborted", "reason": "interrupted"])]]))
        XCTAssertEqual(rows.last?.kindName, "interrupted", dump(rows))
        XCTAssertFalse(rows.contains { if case let .command(c) = $0 { return c.status == .running }; return false }, dump(rows))
    }

    func testUserMessageAppearsOnceAndSkipsAgentsMD() {
        let rows = rows(rollout([userMessage("# AGENTS.md instructions\n\n<INSTRUCTIONS>x</INSTRUCTIONS>"),
                                 userMessage("<environment_context>cwd</environment_context>"),
                                 userMessage("hello"), assistant("hi")]))
        XCTAssertEqual(dump(rows), "user: hello\nassistant: hi")
    }

    func testCommentaryThenFinalAnswer() {
        let rows = rows(rollout([userMessage("go"), assistant("I'll look.\n", phase: "commentary"),
                                 execCommand("ls", callID: "c1", output: "a\n", exit: 0), assistant("Found a.")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant", "command", "assistant"], dump(rows))
    }

    func testReasoningSummaryIsThinking() {
        let rows = rows(rollout([userMessage("go"),
                                 [record("response_item", ["type": "reasoning", "summary": [["type": "summary_text", "text": "**Planning**"]],
                                                           "encrypted_content": "gAAAA"])],
                                 [record("response_item", ["type": "reasoning", "summary": [], "encrypted_content": "gAAAA"])],
                                 assistant("ok")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "thinking", "assistant"], dump(rows))
    }

    func testImageInUserMessage() {
        let line = record("response_item", ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "what is this?"], ["type": "input_image", "image_url": "data:image/png;base64,AAAA"]]])
        let rows = rows(rollout([[line], assistant("a cat")]))
        guard case let .user(_, text, _)? = rows.first else { return XCTFail(dump(rows)) }
        XCTAssertTrue(text.hasPrefix("what is this?"), text)
        XCTAssertFalse(text.contains("base64"), text)
    }

    func testMCPWebSearchSubagentAndUnknownTools() {
        let rows = rows(rollout([
            userMessage("go"),
            [record("response_item", ["type": "function_call", "name": "spawn_agent", "namespace": "collaboration", "call_id": "s1",
                                      "arguments": jsonLine(["task_name": "verify", "agent_type": "fact-checker", "message": "x"])])],
            [record("response_item", ["type": "function_call_output", "call_id": "s1", "output": jsonLine(["task_name": "/root/verify"])])],
            [record("response_item", ["type": "function_call", "name": "js", "namespace": "mcp__cua_repl", "call_id": "m1",
                                      "arguments": jsonLine(["code": "1+1"])])],
            [record("response_item", ["type": "function_call_output", "call_id": "m1", "output": "2"])],
            [record("response_item", ["type": "web_search_call", "status": "completed", "action": ["type": "search", "query": "swift 6"]])],
            [record("response_item", ["type": "brand_new_kind", "foo": "bar"])],
            [record("brand_new_record", ["anything": 1])],
            assistant("done"),
        ]))
        let tools = rows.compactMap { row -> ChatTool? in if case let .tool(t) = row { return t }; return nil }
        XCTAssertEqual(tools.count, 2, dump(rows))
        XCTAssertTrue(tools.allSatisfy { $0.status == .ok }, dump(rows))
        let agents = rows.compactMap { row -> ChatAgent? in if case let .agent(a) = row { return a }; return nil }
        XCTAssertEqual(agents.map(\.title), ["verify"], dump(rows))
        XCTAssertEqual(agents.first?.type, "fact-checker")
        XCTAssertEqual(agents.first?.status, .running, "no SubAgentActivity completed record yet")
        XCTAssertEqual(rows.last?.kindName, "assistant")
    }

    func testFileChangeFromCodeModeExec() {
        let rows = rows(rollout([userMessage("edit"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "p1", "name": "exec",
                                      "input": "text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: a.txt\\n@@\\n-a\\n+b\\n*** End Patch\"));"])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "FileChange", "id": "exec-1", "status": "completed",
                                                                    "changes": ["/r/a.txt": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-a\n+b\n"]]]])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "p1", "output": [["type": "input_text", "text": "{}"]]])],
            assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "edit", "assistant"], dump(rows))
    }

    /// `apply_patch` adding a file: its content arrives without `+` signs, still an edit card.
    func testAddedFileFromCodeModeIsAnEditCard() {
        let rows = rows(rollout([userMessage("make it"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "p1", "name": "exec",
                                      "input": "text(await tools.apply_patch(\"*** Begin Patch\\n*** Add File: n.txt\\n+a\\n*** End Patch\"));"])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "FileChange", "id": "exec-1", "status": "completed",
                                                                    "changes": ["/r/n.txt": ["type": "add", "content": "alpha\nbeta\ngamma\n"]]]])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "p1", "output": [["type": "input_text", "text": "Script completed\nOutput:\n"]]])],
            assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "edit", "assistant"], dump(rows))
        guard case let .edit(e) = rows[1] else { return }
        XCTAssertEqual([e.additions, e.deletions], [3, 0])
        XCTAssertEqual(e.lines.map(\.text), ["alpha", "beta", "gamma"])
    }

    /// MCP calls, web searches and image views made inside `exec` get their own rows; `wait`
    /// calls and sub-agent bookkeeping don't show.
    func testCodeModeNativeToolRecords() {
        let rows = rows(rollout([userMessage("go"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "x1", "name": "exec",
                                      "input": "text(await tools.mcp__context_mode__ctx_search({queries:['a']}));"])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "McpToolCall", "id": "exec-m", "server": "context-mode",
                                                                    "tool": "ctx_search", "arguments": ["queries": ["a"]], "status": "completed",
                                                                    "result": ["content": [["type": "text", "text": "found a"]]]]])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "Extension", "kind": "web.search", "id": "exec-w",
                                                                    "query": "swift 6 release", "action": ["type": "search"]]])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "ImageView", "id": "exec-i", "path": "file:///tmp/shot.png"]])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "id": "s", "kind": "started"]])],
            [record("event_msg", ["type": "item_completed", "item": ["type": "CollabAgentToolCall", "id": "c", "tool": "wait", "status": "completed"]])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "x1", "output": [["type": "input_text", "text": "Script running"]]])],
            [record("response_item", ["type": "function_call", "name": "wait", "call_id": "w1", "arguments": "{\"cell_id\":\"3\"}"])],
            [record("response_item", ["type": "function_call_output", "call_id": "w1", "output": "Script completed"])],
            assistant("done")]))
        let tools = rows.compactMap { row -> ChatTool? in if case let .tool(t) = row { return t }; return nil }
        XCTAssertEqual(tools.map(\.lead), ["MCP", "Web", "View image"], dump(rows))
        XCTAssertEqual(tools.first?.body, "found a")
        XCTAssertEqual(tools.dropFirst().first?.subject, "swift 6 release")
        XCTAssertEqual(tools.last?.subject, "tmp/shot.png")
        XCTAssertTrue(tools.allSatisfy { $0.status == .ok }, dump(rows))
    }

    /// A script that did nothing the rollout records natively still shows its output once.
    func testExecWithoutNativeRecordsShowsItsOutput() {
        let rows = rows(rollout([userMessage("go"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "x1", "name": "exec",
                                      "input": "text(1 + 1);"])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "x1",
                                      "output": [["type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"],
                                                 ["type": "input_text", "text": "2"]]])],
            assistant("done")]))
        XCTAssertEqual(dump(rows), "user: go\ntool[ok]: Script  | 2\nassistant: done")
    }

    /// Older codex-cli code mode wrote no CommandExecution: the command takes the script's output,
    /// an MCP call is named after its tool, and `write_stdin` polls don't show.
    func testOlderCodeModeWithoutNativeRecords() {
        func exec(_ id: String, _ script: String, _ out: String) -> [String] {
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": id, "name": "exec", "input": script]),
             record("response_item", ["type": "custom_tool_call_output", "call_id": id, "output": [
                ["type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"], ["type": "input_text", "text": out]]])]
        }
        let rows = rows(rollout([userMessage("go"),
            exec("a", "text(await tools.exec_command({cmd:\"ls nope\"}));", jsonLine(["exit_code": 1, "output": "ls: nope: No such file\n"])),
            exec("b", "text(await tools.mcp__context_mode__ctx_execute({code:'ls'}));", "a b"),
            exec("c", "text(await tools.write_stdin({session_id:1,chars:''}));", "more"),
            assistant("done")]))
        XCTAssertEqual(dump(rows), "user: go\ncommand[error]: ls nope | ls: nope: No such file\ntool[ok]: MCP Ctx execute | a b\nassistant: done")
    }

    /// codex-cli 0.166 code mode: `tools.apply_patch` inside `exec` with no FileChange record; the
    /// script returns `{}`. 180 such calls in 7 real rollouts. Expected an edit card, not `Script {}`.
    func testOlderCodeModeApplyPatchIsAnEditCard() {
        let rows = rows(rollout([userMessage("edit"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "p1", "name": "exec",
                                      "input": "text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /r/a.txt\\n@@\\n-a\\n+b\\n*** End Patch\\n\"));"])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "p1", "output": [
                ["type": "input_text", "text": "Script completed\nWall time 0.0 seconds\nOutput:\n"], ["type": "input_text", "text": "{}"]]])],
            assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "edit", "assistant"], dump(rows))
    }

    /// codex-cli 0.166: one script that patches and then runs a command (as in real rollout
    /// rollout-2026-10-31T10-22-15-01a192fb…, record 205). Expected the edit card and the command.
    func testOlderCodeModeApplyPatchWithCommandInOneScript() {
        let script = "text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /r/a.txt\\n@@\\n-a\\n+b\\n*** End Patch\\n\"));\n"
            + "text(await tools.exec_command({cmd:\"npm test\"}));"
        let rows = rows(rollout([userMessage("edit"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "p2", "name": "exec", "input": script])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "p2", "output": [
                ["type": "input_text", "text": "Script completed\nWall time 0.0 seconds\nOutput:\n"], ["type": "input_text", "text": "{}"],
                ["type": "input_text", "text": jsonLine(["exit_code": 0, "output": "ok\n"])]]])],
            assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "edit", "command", "assistant"], dump(rows))
    }

    func testFailedOlderCodeModeApplyPatchIsNotAnEditCard() {
        let rows = rows(rollout([userMessage("edit"),
            [record("response_item", ["type": "custom_tool_call", "status": "completed", "call_id": "p1", "name": "exec",
                                      "input": "text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /r/a.txt\\n@@\\n-a\\n+b\\n*** End Patch\\n\"));"])],
            [record("response_item", ["type": "custom_tool_call_output", "call_id": "p1", "output": [
                ["type": "input_text", "text": "Script failed\nWall time 0.0 seconds\nOutput:\n"], ["type": "input_text", "text": "patch did not apply"]]])],
            assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "tool", "assistant"], dump(rows))
    }

    func testTwoIdenticalCommandsBothShow() {
        let rows = rows(rollout([userMessage("go"), execCommand("ls", callID: "c1", output: "a\n", exit: 0),
                                 execCommand("ls", callID: "c2", output: "a\n", exit: 0), assistant("done")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "command", "command", "assistant"], dump(rows))
    }

    func testFailedFileChangeIsNotAnEditCard() {
        let rows = rows(rollout([userMessage("edit"),
            [record("event_msg", ["type": "item_completed", "item": ["type": "FileChange", "id": "exec-1", "status": "failed",
                                                                    "changes": ["/r/a.txt": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-a\n+b\n"]]]])]]))
        XCTAssertFalse(rows.contains { $0.kindName == "edit" }, dump(rows))
    }

    func testCompactionRecordsDoNotBreakTheTimeline() {
        let rows = rows(rollout([userMessage("one"), assistant("first"),
                                 [record("compacted", ["message": "summary of the conversation", "replacement_history": []])],
                                 [record("event_msg", ["type": "item_completed", "item": ["type": "ContextCompaction", "id": "x"]])],
                                 userMessage("two"), assistant("second")]))
        XCTAssertEqual(dump(rows), "user: one\nassistant: first\nuser: two\nassistant: second")
    }

    func testTruncatedLastLineWaitsForTheRest() {
        let full = rollout([userMessage("hi"), assistant("hello")])
        let cut = full + String(record("response_item", ["type": "message", "role": "assistant",
                                                         "content": [["type": "output_text", "text": "more"]]]).prefix(40))
        var feed = TimelineFeed(agent: .codex)
        feed.feed(chunk: Data(cut.utf8))
        XCTAssertEqual(feed.offset, full.utf8.count)
        XCTAssertEqual(ChatRows.build(feed.entries, working: false), rows(full))
    }

    func testMalformedLineInTheMiddleIsSkipped() {
        let text = rollout([userMessage("hi"), ["{not json at all"], assistant("hello")])
        XCTAssertEqual(dump(rows(text)), "user: hi\nassistant: hello")
    }

    func testUnicodeAndLongLinesSurvive() {
        let long = String(repeating: "x", count: 50_000)
        let text = "日本語 中文 🎉👩‍👩‍👧 مرحبا e\u{301} \(long)"
        let rows = rows(rollout([userMessage(text), assistant(text)]))
        XCTAssertEqual(rows, [.user(id: rows.first?.id ?? "", text: text, queued: false),
                              .assistant(id: rows.last?.id ?? "", text: text, streaming: false)])
    }

    func testEmptyRollout() {
        XCTAssertEqual(rows(""), [])
        XCTAssertEqual(rows(rollout([])), [])
    }

    func testStreamingCursorOnTheLastReplyWhileWorking() {
        let rows = rows(rollout([userMessage("hi"), assistant("hel", phase: "commentary")]), working: true)
        XCTAssertEqual(rows.last, .assistant(id: rows.last?.id ?? "", text: "hel", streaming: true))
    }

    func testTenThousandEntriesParseQuickly() {
        var parts: [[String]] = []
        for i in 0..<2_500 {
            parts.append(userMessage("question \(i)"))
            parts.append(execCommand("echo \(i)", callID: "c\(i)", output: "\(i)\n", exit: 0))
            parts.append(assistant("answer \(i)"))
        }
        let text = rollout(parts)
        let start = Date()
        let rows = rows(text)
        let elapsed = Date().timeIntervalSince(start)
        print("10k codex: \(rows.count) rows, \(text.utf8.count / 1024) KB, \(Int(elapsed * 1000)) ms")
        XCTAssertGreaterThanOrEqual(rows.count, 7_500)
        // The budget is the Mac app's; Linux runs these only to keep AgTermCore building there.
        #if !os(Linux)
        XCTAssertLessThan(elapsed, 0.3)
        #endif
    }

    /// Appending one line to a big rollout: the feed re-folds every kept record, so each poll costs a full fold.
    func testAppendingToALargeRolloutStaysCheap() {
        var parts: [[String]] = []
        for i in 0..<2_500 { parts.append(userMessage("q \(i)")); parts.append(assistant("a \(i)")) }
        var feed = TimelineFeed(agent: .codex)
        feed.feed(chunk: Data(rollout(parts).utf8))
        let start = Date()
        for i in 0..<10 { feed.feed(chunk: Data((assistant("more \(i)").joined(separator: "\n") + "\n").utf8)) }
        let perAppend = Date().timeIntervalSince(start) / 10
        print("codex append on 10k records: \(Int(perAppend * 1000)) ms each")
        XCTAssertLessThan(perAppend, 0.05)
    }
}

/// Opt-in: `AGTERM_CODEX_BIG=<rollout path>` opens a real rollout minus its last 20 lines, then
/// appends those one line at a time (one poll each) and checks the result matches a whole read.
final class ChatCodexBigRolloutTests: XCTestCase {
    func testOpenAndAppendRealBigRollout() throws {
        guard let path = ProcessInfo.processInfo.environment["AGTERM_CODEX_BIG"] else { throw XCTSkip("set AGTERM_CODEX_BIG") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var cuts: [Int] = []
        for (i, byte) in data.enumerated().reversed() where byte == 0x0A { cuts.append(i + 1); if cuts.count == 21 { break } }
        let head = cuts.last ?? 0
        var start = Date()
        var feed = TimelineFeed(agent: .codex)
        _ = feed.feed(chunk: data[0..<head])
        let rowsAtOpen = ChatRows.build(feed.entries, working: true)
        let open = Date().timeIntervalSince(start)
        start = Date()
        var at = head
        for cut in cuts.dropLast().reversed() {
            _ = feed.feed(chunk: data[at..<cut]); at = cut
            _ = ChatRows.build(feed.entries, working: true)
        }
        let perAppend = Date().timeIntervalSince(start) / 20
        var whole = TimelineFeed(agent: .codex)
        _ = whole.feed(chunk: data)
        print("big codex rollout \(data.count / 1024) KB: open \(Int(open * 1000)) ms (\(rowsAtOpen.count) rows), append \(Int(perAppend * 1000)) ms each")
        XCTAssertEqual(ChatRows.build(feed.entries, working: false), ChatRows.build(whole.entries, working: false))
        XCTAssertLessThan(open, 0.3)
        XCTAssertLessThan(perAppend, 0.02)
    }
}

/// Opt-in: `AGTERM_CODEX_CORPUS=1` sweeps up to 200 of `~/.codex/sessions/**/*.jsonl` (largest first, then newest)
/// through the feed and the rows model, read-only, and writes a report to `AGTERM_CODEX_CORPUS_REPORT`.
final class ChatCodexCorpusSweepTests: XCTestCase {
    func testCorpusSweep() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGTERM_CODEX_CORPUS"] == "1" else { throw XCTSkip("set AGTERM_CODEX_CORPUS=1") }
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
        let all = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }) ?? []
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var picked = Array(all.sorted { size($0) > size($1) }.prefix(120))
        for u in all.sorted(by: { date($0) > date($1) }) where picked.count < 200 && !picked.contains(u) { picked.append(u) }

        var report: [String] = []
        var rowKinds: [String: Int] = [:]
        var toolLeads: [String: Int] = [:]
        var ignoredTypes: [String: Int] = [:]
        var totals = (users: 0, userRows: 0, replies: 0, replyRows: 0, execs: 0, commandRows: 0, fileChanges: 0, editRows: 0,
                      emptyText: 0, chunkMismatch: 0, badJSON: 0)
        var native: [String: Int] = [:]
        var commandStatus: [String: Int] = [:]
        var slowest: [(String, Double, Int)] = []
        let handled: Set = ["message", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output",
                            "reasoning", "web_search_call", "tool_search_call", "tool_search_output", "image_generation_call",
                            "local_shell_call", "user_message", "patch_apply_end", "turn_aborted"]

        for (n, url) in picked.enumerated() {
            let data = try Data(contentsOf: url)
            let start = Date()
            var feed = TimelineFeed(agent: .codex)
            feed.feed(chunk: data)
            let rows = ChatRows.build(feed.entries, working: false)
            let elapsed = Date().timeIntervalSince(start)
            slowest.append((url.lastPathComponent, elapsed, data.count))

            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let v = JSONValue.parse(String(line)) else { totals.badJSON += 1; continue }
                let type = v["type"]?.string ?? "?"
                let pType = v["payload"]?["type"]?.string ?? ""
                let key = pType.isEmpty ? type : "\(type).\(pType)"
                if pType == "message" {
                    let role = v["payload"]?["role"]?.string
                    let text = (v["payload"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined()
                    if role == "user", !CodexTimeline.isSystemUserMessage(text), !text.isBlank { totals.users += 1 }
                    if role == "assistant", !text.isBlank { totals.replies += 1 }
                } else if pType == "custom_tool_call", v["payload"]?["name"]?.string == "exec" {
                    let input = v["payload"]?["input"]?.string ?? ""
                    if input.contains("tools.exec_command") { totals.execs += 1 }
                } else if pType == "item_completed", v.pointer("/payload/item/type")?.string == "FileChange",
                          v.pointer("/payload/item/status")?.string == "completed" {
                    totals.fileChanges += (v.pointer("/payload/item/changes")?.object?.count ?? 0)
                }
                if pType == "item_completed", let it = v.pointer("/payload/item/type")?.string {
                    let kind = it == "Extension" ? "Extension." + (v.pointer("/payload/item/kind")?.string ?? "?") : it
                    native[kind, default: 0] += 1
                }
                if !handled.contains(pType) {
                    let sub = pType == "item_completed" ? "." + (v.pointer("/payload/item/type")?.string ?? "?") : ""
                    ignoredTypes[key + sub, default: 0] += 1
                }
            }
            for row in rows {
                rowKinds[row.kindName, default: 0] += 1
                switch row {
                case let .user(_, text, _): totals.userRows += 1; if text.isBlank { totals.emptyText += 1 }
                case let .assistant(_, text, _): totals.replyRows += 1; if text.isBlank { totals.emptyText += 1 }
                case let .command(c): totals.commandRows += 1; commandStatus["\(c.status)", default: 0] += 1
                case .edit: totals.editRows += 1
                case let .tool(t): toolLeads["\(t.lead)/\(t.verb)", default: 0] += 1
                case let .tools(_, tools, _): tools.forEach { toolLeads["folded:\($0.verb)", default: 0] += 1 }
                default: break
                }
            }
            // Chunked feeding must match a whole read on a sample.
            if n % 10 == 0 {
                var chunked = TimelineFeed(agent: .codex)
                var pending = Data()
                var at = 0
                while at < data.count {
                    pending += data[at..<min(at + 65_536, data.count)]
                    pending = pending.dropFirst(chunked.feed(chunk: pending))
                    at += 65_536
                }
                if chunked.entries != feed.entries { totals.chunkMismatch += 1; report.append("CHUNK MISMATCH \(url.path)") }
            }
        }
        slowest.sort { $0.1 > $1.1 }
        report.insert("files: \(picked.count) of \(all.count)", at: 0)
        report.append("totals: \(totals)")
        report.append("native item_completed kinds: \(native.sorted { $0.value > $1.value })")
        report.append("command row status: \(commandStatus)")
        report.append("row kinds: \(rowKinds.sorted { $0.value > $1.value })")
        report.append("tool row leads: \(toolLeads.sorted { $0.value > $1.value }.prefix(40))")
        report.append("record kinds the parser ignores: \(ignoredTypes.sorted { $0.value > $1.value })")
        report.append("slowest (debug build): " + slowest.prefix(8).map { "\($0.0) \(Int($0.1 * 1000))ms \($0.2 / 1024)KB" }.joined(separator: "; "))
        report.append("total parse: \(Int(slowest.map(\.1).reduce(0, +) * 1000)) ms")
        let text = report.joined(separator: "\n")
        print(text)
        if let out = env["AGTERM_CODEX_CORPUS_REPORT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

/// Opt-in: `AGTERM_CODEX_PATCHFILE=<rollout path>` prints how many edit cards a real rollout
/// gives and checks every row id is unique (no doubled cards). `AGTERM_CODEX_PATCH_EXPECT=<n>` checks the count.
final class ChatCodexPatchFileTests: XCTestCase {
    func testRealRolloutEditCards() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AGTERM_CODEX_PATCHFILE"] else { throw XCTSkip("set AGTERM_CODEX_PATCHFILE") }
        var feed = TimelineFeed(agent: .codex)
        feed.feed(chunk: try Data(contentsOf: URL(fileURLWithPath: path)))
        let rows = ChatRows.build(feed.entries, working: false)
        let edits = rows.compactMap { row -> ChatEdit? in if case let .edit(e) = row { return e }; return nil }
        print("patchfile edits=\(edits.count) rows=\(rows.count) scripts=\(rows.filter { if case let .tool(t) = $0 { return t.lead == "Script" }; return false }.count)")
        for e in edits.prefix(env["AGTERM_CODEX_PATCH_ALL"] == nil ? 5 : .max) { print("  edit \(e.verb) \(e.path) +\(e.additions) -\(e.deletions) lines=\(e.lines.count)") }
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "duplicate row ids")
        if let expect = env["AGTERM_CODEX_PATCH_EXPECT"].flatMap(Int.init) { XCTAssertEqual(edits.count, expect) }
    }
}
