import XCTest
@testable import AgTermCore

/// Claude Code transcripts through the chat's reader (`TimelineFeed`) and rows model (`ChatRows`),
/// one test per situation in the chat spec. Two opt-in sweeps read real files:
/// `CHAT_CLAUDE_FIXTURES=<dir of .jsonl>` dumps their rows, `CHAT_CLAUDE_CORPUS=1` parses a sample
/// of `~/.claude/projects/**/*.jsonl` and reports drops, unknown kinds and timings.
final class ChatClaudeScenarioTests: XCTestCase {
    let ts = "2026-11-08T12:00:00.000Z"

    func line(_ type: String, _ uuid: String, _ content: Any, ts: String? = nil, extra: [String: Any] = [:]) -> String {
        jsonLine(["type": type, "uuid": uuid, "timestamp": ts ?? self.ts, "message": ["content": content]].merging(extra) { $1 })
    }

    func toolUse(_ uuid: String, id: String, name: String, input: [String: Any], ts: String? = nil) -> String {
        line("assistant", uuid, [["type": "tool_use", "id": id, "name": name, "input": input]], ts: ts)
    }

    func toolResult(_ uuid: String, id: String, content: Any, error: Bool = false, ts: String? = nil) -> String {
        line("user", uuid, [["type": "tool_result", "tool_use_id": id, "content": content, "is_error": error]], ts: ts)
    }

    func rows(_ lines: [String], working: Bool = false) -> [ChatRow] {
        var feed = TimelineFeed(agent: .claude)
        feed.feed(chunk: Data((lines.joined(separator: "\n") + "\n").utf8))
        return ChatRows.build(feed.entries, working: working)
    }

    // MARK: Replies

    func testPlainReply() {
        let r = rows([line("user", "u1", "hi"), line("assistant", "a1", [["type": "text", "text": "Hi there."]])])
        XCTAssertEqual(r, [.user(id: "u1", text: "hi", queued: false), .assistant(id: "a1", text: "Hi there.", streaming: false)])
    }

    func testMarkdownNestedFences() {
        let md = "## Demo\n\n- one\n- two\n\n1. a\n2. b\n\n````python\ns = \"```\"\n````\n\n~~~sh\necho hi\n~~~"
        let r = rows([line("assistant", "a1", [["type": "text", "text": md]])])
        guard case .assistant(_, let text, _)? = r.first else { return XCTFail("no reply: \(r)") }
        let lines = ChatText.lines(text)
        XCTAssertTrue(lines.contains(.code(["s = \"```\""])), "\(lines)")
        XCTAssertTrue(lines.contains(.code(["echo hi"])), "\(lines)")
        XCTAssertTrue(lines.contains { if case .heading = $0 { return true }; return false })
    }

    func testVeryLongReplyAndLongUnbrokenLine() {
        let long = String(repeating: "word ", count: 40_000) + String(repeating: "x", count: 50_000)
        let r = rows([line("assistant", "a1", [["type": "text", "text": long]])])
        guard case .assistant(_, let text, _)? = r.first else { return XCTFail() }
        XCTAssertEqual(text.count, long.rustTrimmed.count, "a long reply is kept whole")
    }

    func testStreamingTailAndPartialLine() {
        let full = line("assistant", "a1", [["type": "text", "text": "Working on it"]])
        var feed = TimelineFeed(agent: .claude)
        let data = Data((line("user", "u1", "go") + "\n" + full).utf8)   // last line has no newline yet
        feed.feed(chunk: data)
        XCTAssertEqual(feed.entries.map(\.id), ["u1"], "the half-written line waits")
        feed.feed(chunk: data.subdata(in: feed.offset..<data.count) + Data("\n".utf8))
        XCTAssertEqual(ChatRows.build(feed.entries, working: true).last,
                       .assistant(id: "a1", text: "Working on it", streaming: true))
    }

    func testThinking() {
        let r = rows([line("assistant", "a1", [["type": "thinking", "thinking": "Plan.", "signature": "x"],
                                               ["type": "text", "text": "Done"]])])
        XCTAssertEqual(r.map(\.kindName), ["thinking", "assistant"])
    }

    /// Current Claude Code writes thinking blocks with an empty `thinking` and only a signature;
    /// the chat still shows the `▸ thinking` line (with nothing to expand).
    func testRedactedThinkingStillShowsALine() {
        let r = rows([line("assistant", "a1", [["type": "thinking", "thinking": "", "signature": "abc"]]),
                      line("assistant", "a2", [["type": "redacted_thinking", "data": "abc"]])])
        XCTAssertEqual(r, [.thinking(id: "a1", text: ""), .thinking(id: "a2", text: "")])
        // The phone timeline still drops them.
        let phone = RemoteTimeline.claude(transcript: [line("assistant", "a1", [["type": "thinking", "thinking": "", "signature": "abc"]])]
            .joined(separator: "\n") + "\n")
        XCTAssertEqual(phone, [])
    }

    // MARK: Tools

    func testReadGrepGlobLsFoldIntoOneLine() {
        let r = rows([
            toolUse("a1", id: "t1", name: "Read", input: ["file_path": "/r/a.swift"], ts: "2026-11-08T12:00:00.000Z"),
            toolResult("u1", id: "t1", content: "1\tx"),
            toolUse("a2", id: "t2", name: "Grep", input: ["pattern": "TODO"]),
            toolResult("u2", id: "t2", content: "a:1"),
            toolUse("a3", id: "t3", name: "Glob", input: ["pattern": "*.py"]),
            toolResult("u3", id: "t3", content: "calc.py"),
            toolUse("a4", id: "t4", name: "LS", input: ["path": "/r"]),
            toolResult("u4", id: "t4", content: "a", ts: "2026-11-08T12:00:00.600Z"),
            line("assistant", "a5", [["type": "text", "text": "ok"]], ts: "2026-11-08T12:00:03.000Z"),
        ])
        guard case .tools(_, let tools, let ms)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual(tools.map(\.verb), ["Read", "Grep", "Glob", "List"])
        XCTAssertEqual(ChatRows.summary(tools), "Read r/a.swift · Grep \"TODO\" · Glob *.py · List r")
        XCTAssertEqual(ms, 600, "from the first call to the last result, not to the next reply")
    }

    func testEditWriteMultiEditCards() {
        let r = rows([
            toolUse("a1", id: "t1", name: "Edit", input: ["file_path": "/r/calc.py", "old_string": "return a + b", "new_string": "return a + b + 0"]),
            toolResult("u1", id: "t1", content: "The file /r/calc.py has been updated successfully."),
            toolUse("a2", id: "t2", name: "Write", input: ["file_path": "/r/new.txt", "content": "First\nSecond\n"]),
            toolResult("u2", id: "t2", content: "File created successfully at: /r/new.txt"),
            toolUse("a3", id: "t3", name: "MultiEdit", input: ["file_path": "/r/m.py", "edits": [
                ["old_string": "a", "new_string": "b"], ["old_string": "c\nd", "new_string": "e"]]]),
            toolResult("u3", id: "t3", content: "ok"),
        ])
        let edits = r.compactMap { row -> ChatEdit? in if case .edit(let e) = row { return e }; return nil }
        XCTAssertEqual(edits.map(\.verb), ["Edit", "Write", "Edit"])
        XCTAssertEqual(edits.map(\.additions), [1, 2, 2])
        XCTAssertEqual(edits.map(\.deletions), [1, 0, 3])
        // The header's counts match the +/- lines the card shows.
        for e in edits {
            XCTAssertEqual(e.additions, e.lines.filter { $0.kind == .added }.count, "\(e.path) +count")
            XCTAssertEqual(e.deletions, e.lines.filter { $0.kind == .removed }.count, "\(e.path) -count")
        }
        XCTAssertEqual(edits[1].lines.map(\.text), ["First", "Second"])
    }

    func testEditPreviewCapsAt12Lines() {
        let new = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let r = rows([toolUse("a1", id: "t1", name: "Write", input: ["file_path": "/r/big", "content": new]),
                      toolResult("u1", id: "t1", content: "ok")])
        guard case .edit(let e)? = r.first else { return XCTFail() }
        XCTAssertEqual(e.preview.count, 12)
        XCTAssertEqual(e.hiddenLines, 28)
    }

    func testBashOkErrorLong() {
        let long = (1...200).map(String.init).joined(separator: "\n")
        let r = rows([
            toolUse("a1", id: "t1", name: "Bash", input: ["command": "ls /nope && echo ok"], ts: "2026-11-08T12:00:00.000Z"),
            toolResult("u1", id: "t1", content: "Exit code 1\nls: /nope: No such file or directory", error: true,
                       ts: "2026-11-08T12:00:01.200Z"),
            toolUse("a2", id: "t2", name: "Bash", input: ["command": "seq 1 200"], ts: "2026-11-08T12:00:01.200Z"),
            toolResult("u2", id: "t2", content: long, ts: "2026-11-08T12:00:01.450Z"),
            line("assistant", "a3", [["type": "text", "text": "done"]], ts: "2026-11-08T12:00:02.400Z"),
        ])
        guard case .command(let bad)? = r.first, case .command(let ok)? = r.dropFirst().first else { return XCTFail("\(r)") }
        XCTAssertEqual(bad.status, .error)
        XCTAssertEqual(bad.errorLines, ["Exit code 1", "ls: /nope: No such file or directory"])
        XCTAssertEqual(bad.durationMs, 1200)
        XCTAssertEqual(ok.durationMs, 250, "until its result, not until the next reply")
        XCTAssertEqual(ok.summary, "1")
        XCTAssertEqual(ok.status, .ok)
        XCTAssertLessThanOrEqual(ok.output?.count ?? 0, TimelineTools.resultBodyLimit + 8, "big output is capped")
    }

    func testToolStillRunning() {
        let r = rows([toolUse("a1", id: "t1", name: "Bash", input: ["command": "sleep 10"])], working: true)
        guard case .command(let c)? = r.first else { return XCTFail() }
        XCTAssertEqual(c.status, .running)
        XCTAssertNil(c.durationMs)
        let read = rows([toolUse("a1", id: "t1", name: "Read", input: ["file_path": "/r/a"])], working: true)
        XCTAssertEqual(read.map(\.kindName), ["tool"], "a running read is not folded away")
    }

    func testToolErrorNotFolded() {
        let r = rows([toolUse("a1", id: "t1", name: "Grep", input: ["pattern": "x"]),
                      toolResult("u1", id: "t1", content: "<tool_use_error>No such tool available: Grep</tool_use_error>", error: true)])
        guard case .tool(let t)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual(t.status, .error)
    }

    /// Real haiku run (claude-tools.jsonl): an unavailable tool's result is wrapped in `<tool_use_error>`.
    func testToolUseErrorTagIsStripped() {
        let r = rows([toolUse("a1", id: "t1", name: "Grep", input: ["pattern": "TODO"]),
                      toolResult("u1", id: "t1", content: "<tool_use_error>Error: No such tool available: Grep.</tool_use_error>", error: true)])
        guard case .tool(let t)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual(t.body, "Error: No such tool available: Grep.")
    }

    func testFailedEditIsNotADiffCard() {
        let r = rows([toolUse("a1", id: "t1", name: "Edit", input: ["file_path": "/r/a", "old_string": "x", "new_string": "y"]),
                      toolResult("u1", id: "t1", content: "String to replace not found", error: true)])
        guard case .tool(let t)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual(t.status, .error)
        XCTAssertEqual(t.body, "String to replace not found")
    }

    func testSubagentTaskAndAgent() {
        let r = rows([toolUse("a1", id: "t1", name: "Agent", input: ["description": "Count lines", "subagent_type": "general-purpose", "prompt": "count"]),
                      toolResult("u1", id: "t1", content: [["type": "text", "text": "3 lines"]]),
                      toolUse("a2", id: "t2", name: "Task", input: ["description": "Explore", "prompt": "look"])])
        XCTAssertEqual(r.map(\.kindName), ["tool", "tool"])
        guard case .tool(let t)? = r.first else { return XCTFail() }
        XCTAssertEqual(t.lead, "Agent")
        XCTAssertEqual(t.body, "3 lines")
    }

    func testWebAndMCPTools() {
        let r = rows([toolUse("a1", id: "t1", name: "WebFetch", input: ["url": "https://x.dev", "prompt": "p"]),
                      toolResult("u1", id: "t1", content: "page"),
                      toolUse("a2", id: "t2", name: "WebSearch", input: ["query": "swift"]),
                      toolResult("u2", id: "t2", content: "results"),
                      toolUse("a3", id: "t3", name: "mcp__linear__create_issue", input: ["title": "x"]),
                      toolResult("u3", id: "t3", content: "ok"),
                      toolUse("a4", id: "t4", name: "SomeBrandNewTool", input: [:])])
        XCTAssertEqual(r.compactMap { if case .tool(let t) = $0 { return t.lead }; return nil }, ["Web", "Web", "MCP", "SomeBrandNewTool"])
    }

    func testServerSideWebSearchBlocks() {
        // Server tools come as `server_tool_use` / `web_search_tool_result` assistant blocks.
        let r = rows([line("assistant", "a1", [["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "q"]],
                                               ["type": "web_search_tool_result", "tool_use_id": "s1", "content": []],
                                               ["type": "text", "text": "Found it"]])])
        XCTAssertEqual(r.map(\.kindName), ["assistant"], "documents today's behavior: server tools are dropped")
    }

    // MARK: User side

    func testImageAttachmentInUserMessage() {
        let r = rows([line("user", "u1", [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]],
                                          ["type": "text", "text": "what is this?"]])])
        XCTAssertEqual(r.map(\.kindName), ["user"])
        guard case .user(_, let text, _)? = r.first else { return XCTFail() }
        XCTAssertEqual(text, "what is this?\n[image]")
    }

    func testImageOnlyUserMessage() {
        let r = rows([line("user", "u1", [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]]])])
        XCTAssertEqual(r, [.user(id: "u1", text: "[image]", queued: false)])
    }

    /// Claude Code's own `[Image #1]` placeholder already names the picture.
    func testImageWithPlaceholderTextAndQueuedImagePrompt() {
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]]
        let r = rows([line("user", "u1", [["type": "text", "text": "[Image #1] fix this"], image]),
                      jsonLine(["type": "attachment", "uuid": "q1", "timestamp": "2026-11-08T12:00:01.000Z",
                                "attachment": ["type": "queued_command", "prompt": [["type": "text", "text": "and this"], image]]])])
        XCTAssertEqual(r, [.user(id: "u1", text: "[Image #1] fix this", queued: false),
                           .user(id: "q1", text: "and this\n[image]", queued: false)])
    }

    func testInterruptedTurn() {
        let r = rows([line("user", "u1", "go"),
                      line("user", "u2", [["type": "text", "text": "[Request interrupted by user]"]]),
                      line("user", "u3", [["type": "text", "text": "[Request interrupted by user for tool use]"]])])
        XCTAssertEqual(r.map(\.kindName), ["user", "interrupted", "interrupted"])
    }

    func testQueuedMessage() {
        let r = rows([line("user", "u1", "go"),
                      jsonLine(["type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": "and push it"])], working: true)
        XCTAssertEqual(r.last, .user(id: "queued-0", text: "and push it", queued: true))
    }

    /// Headless `claude -p` writes enqueue + content-less dequeue for the first prompt; no queued row may stay.
    func testHeadlessEnqueueDequeueLeavesNoQueuedRow() {
        let r = rows([jsonLine(["type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": "hi"]),
                      jsonLine(["type": "queue-operation", "operation": "dequeue", "timestamp": ts]),
                      line("user", "u1", "hi")])
        XCTAssertEqual(r, [.user(id: "u1", text: "hi", queued: false)])
    }

    func testSlashCommandAndSystemNoise() {
        let r = rows([line("user", "u1", "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"),
                      line("user", "u2", "<local-command-stdout></local-command-stdout>"),
                      line("user", "u3", "/model opus", extra: ["isMeta": true])])
        XCTAssertEqual(r.map(\.id), ["u3"])
    }

    func testCompactionSummaryHidden() {
        let r = rows([jsonLine(["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted", "timestamp": ts]),
                      line("user", "u1", "This session is being continued from a previous conversation...", extra: ["isCompactSummary": true]),
                      jsonLine(["type": "summary", "summary": "Fixed tests", "leafUuid": "x"]),
                      line("user", "u2", "next")])
        XCTAssertEqual(r.map(\.id), ["u2"])
    }

    /// Claude's Edit result carries the real hunk (`toolUseResult.structuredPatch`); the card should
    /// show that (+2 −1 here), not every old line removed and every new line added.
    func testEditUsesRealPatchCounts() {
        let old = "def add(a, b):\n    return a + b\n"
        let new = "def add(a, b):\n    \"\"\"Doc.\"\"\"\n    return a + b + 0\n"
        let r = rows([toolUse("a1", id: "t1", name: "Edit", input: ["file_path": "/r/calc.py", "old_string": old, "new_string": new]),
                      line("user", "u1", [["type": "tool_result", "tool_use_id": "t1", "content": "updated"]], extra: ["toolUseResult": [
                          "filePath": "/r/calc.py", "oldString": old, "newString": new,
                          "structuredPatch": [["oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 3,
                                               "lines": [" def add(a, b):", "-    return a + b", "+    \"\"\"Doc.\"\"\"", "+    return a + b + 0"]]]]])])
        guard case .edit(let e)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual([e.additions, e.deletions], [2, 1])
    }

    /// Background task / monitor notifications reach the transcript as `queued_command` attachments;
    /// they must not show as a user message full of XML.
    func testQueuedTaskNotificationIsNotARawUserRow() {
        let note = "<task-notification>\n<task-id>b1</task-id>\n<summary>Monitor event</summary>\n</task-notification>"
        let r = rows([line("user", "u1", "go"),
                      jsonLine(["type": "attachment", "uuid": "q1", "timestamp": ts, "attachment": ["type": "queued_command", "prompt": note]])])
        XCTAssertFalse(r.contains { if case .user(_, let t, _) = $0 { return t.contains("<task-") }; return false }, "\(r)")
    }

    /// Newer Claude Code also delivers them as a plain `user` string record with
    /// `origin.kind = "task-notification"` (seen in corpus file d7ae251c…, line 5408).
    func testTaskNotificationUserRecordIsNotARawUserRow() {
        let note = "<task-notification>\n<task-id>a99</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<output-file>/tmp/a99.output</output-file>\n"
            + "<status>completed</status>\n<summary>Agent done</summary>\n<result>Changed `x.mjs`: ok.</result>\n"
            + "<usage><subagent_tokens>5</subagent_tokens><tool_uses>3</tool_uses><duration_ms>72817</duration_ms></usage>\n</task-notification>"
        let r = rows([line("user", "u1", "go"),
                      line("user", "n1", note, extra: ["origin": ["kind": "task-notification", "producer": "session-task"],
                                                       "promptSource": "system", "turnOrigin": "task_notification"])])
        XCTAssertFalse(r.contains { if case .user(_, let t, _) = $0 { return t.contains("<task-") }; return false }, "\(r)")
    }

    /// Claude Code's queue isn't FIFO: a content-less `dequeue` can take a later notification and a
    /// `remove` the earlier one. Sequence copied from corpus file d7ae251c… lines 5376–5405; the
    /// finished transcript must not end with a stale "queued" bubble full of `<task-notification>` XML.
    func testQueueNotFIFOLeavesNoStaleNotification() {
        func note(_ id: String) -> String { "<task-notification>\n<task-id>\(id)</task-id>\n<summary>s</summary>\n</task-notification>" }
        func op(_ o: String, _ content: String? = nil) -> String {
            var d: [String: Any] = ["type": "queue-operation", "operation": o, "timestamp": ts]
            if let content { d["content"] = content }
            return jsonLine(d)
        }
        let r = rows([line("user", "u1", "go"),
                      op("enqueue", note("B")), op("enqueue", note("G")), op("dequeue"),
                      op("remove", note("B")),
                      op("enqueue", note("A")), op("dequeue"),
                      line("user", "n1", note("A"), extra: ["origin": ["kind": "task-notification"]]),
                      line("assistant", "a1", [["type": "text", "text": "done"]])])
        XCTAssertFalse(r.contains { if case .user(_, let t, _) = $0 { return t.contains("<task-") }; return false }, "\(r)")
        XCTAssertFalse(r.contains { if case .user(_, _, true) = $0 { return true }; return false }, "no queued row stays: \(r)")
    }

    /// Whatever is still queued must not show raw notification XML either.
    func testPendingQueuedNotificationIsCleaned() {
        let n = "<task-notification>\n<task-id>x</task-id>\n<summary>s</summary>\n</task-notification>"
        let r = rows([line("user", "u1", "go"),
                      jsonLine(["type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": n])], working: true)
        XCTAssertFalse(r.contains { if case .user(_, let t, _) = $0 { return t.contains("<task-") }; return false }, "\(r)")
    }

    /// `!cmd` in Claude Code writes `<bash-input>` / `<bash-stdout>` user strings.
    func testBangShellCommandIsNotRawXML() {
        let r = rows([line("user", "u1", "<bash-input>ls</bash-input>"),
                      line("user", "u2", "<bash-stdout>a\nb</bash-stdout><bash-stderr></bash-stderr>")])
        XCTAssertFalse(r.contains { if case .user(_, let t, _) = $0 { return t.contains("<bash-") }; return false }, "\(r)")
        guard case .command(let c)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(c.command, "ls")
        XCTAssertEqual(c.status, .ok)
        XCTAssertEqual(c.output, "a\nb")
    }

    func testAgentRowShowsDescriptionAndNoSummaryTag() {
        let r = rows([toolUse("a1", id: "t1", name: "Agent", input: ["description": "Count lines in notes.txt",
                                                                      "prompt": "Count the lines in the file named notes.txt. The primary working directory is /tmp"]),
                      toolResult("u1", id: "t1", content: [["type": "text", "text": "<tools-used-before-summary>Bash</tools-used-before-summary>\n\n3 lines"]])])
        guard case .tool(let t)? = r.first else { return XCTFail("\(r)") }
        XCTAssertEqual(t.subject, "Count lines in notes.txt")
        XCTAssertFalse(t.body?.contains("<tools-used") ?? true, t.body ?? "")
        XCTAssertEqual(t.body?.trimmingCharacters(in: .whitespacesAndNewlines), "3 lines")
    }

    func testWriteWithTrailingNewlineCountsItsLines() {
        XCTAssertEqual(TimelineTools.contentLineCount("First line\nSecond line\n"), 2)
        XCTAssertEqual(TimelineTools.contentLineCount("a\n\n"), 2)
        XCTAssertEqual(TimelineTools.contentLineCount("a"), 1)
        XCTAssertEqual(TimelineTools.contentLineCount(""), 0)
    }

    // MARK: Robustness

    func testMalformedAndUnknownLines() {
        let r = rows([line("user", "u1", "hi"), "{not json", "", "   ", jsonLine(["type": "brand-new-kind", "x": 1]),
                      jsonLine(["type": "assistant", "message": "not an object"]),
                      jsonLine(["type": "assistant", "uuid": "a1", "message": ["content": [["type": "future_block"], ["type": "text", "text": "ok"]]]]),
                      line("assistant", "a2", [["type": "text", "text": "after"]])])
        XCTAssertEqual(r.map(\.id), ["u1", "a1-1", "a2"])
    }

    func testTruncatedLastLineThenCompletes() {
        let good = line("user", "u1", "hi")
        let partial = String(line("assistant", "a1", [["type": "text", "text": "hello"]]).prefix(30))
        var feed = TimelineFeed(agent: .claude)
        feed.feed(chunk: Data((good + "\n" + partial).utf8))
        XCTAssertEqual(feed.entries.map(\.id), ["u1"])
        XCTAssertEqual(feed.offset, good.utf8.count + 1)
    }

    func testUnicode() {
        let texts = ["你好世界 漢字", "🧑‍💻👍🏽 emoji", "مرحبا بالعالم", "cafe\u{301} n\u{303}", String(repeating: "あ", count: 5000)]
        let r = rows(texts.enumerated().map { line("assistant", "a\($0.offset)", [["type": "text", "text": $0.element]]) })
        XCTAssertEqual(r.compactMap { if case .assistant(_, let t, _) = $0 { return t }; return nil }, texts)
    }

    /// A chunk boundary inside a multi-byte character must not corrupt the line.
    func testChunkSplitInsideMultibyteCharacter() {
        let data = Data((line("assistant", "a1", [["type": "text", "text": "你好🧑‍💻"]]) + "\n").utf8)
        let cut = data.firstIndex(of: 0xE4)! + 1
        var feed = TimelineFeed(agent: .claude)
        feed.feed(chunk: data.subdata(in: 0..<cut))
        feed.feed(chunk: data.subdata(in: feed.offset..<data.count))
        XCTAssertEqual(feed.entries.first?.text, "你好🧑‍💻")
    }

    func testEmptyTranscript() {
        var feed = TimelineFeed(agent: .claude)
        XCTAssertEqual(feed.feed(chunk: Data()), 0)
        XCTAssertEqual(ChatRows.build(feed.entries, working: false), [])
    }

    func testNewSessionFileNeedsNewFeed() {
        var old = TimelineFeed(agent: .claude)
        old.feed(chunk: Data((line("user", "u1", "old") + "\n").utf8))
        var fresh = TimelineFeed(agent: .claude)   // /clear writes a new <session>.jsonl
        fresh.feed(chunk: Data((line("user", "n1", "new") + "\n").utf8))
        XCTAssertEqual(ChatRows.build(fresh.entries, working: false).map(\.id), ["n1"])
    }

    func testTenThousandEntriesFast() {
        var lines: [String] = []
        for i in 0..<5_000 {
            lines.append(toolUse("a\(i)", id: "t\(i)", name: i % 3 == 0 ? "Bash" : "Read", input: ["command": "echo \(i)", "file_path": "/r/f\(i)"]))
            lines.append(toolResult("u\(i)", id: "t\(i)", content: "out \(i)"))
            lines.append(line("assistant", "x\(i)", [["type": "text", "text": "step \(i) **done**"]]))
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let start = Date()
        var feed = TimelineFeed(agent: .claude)
        feed.feed(chunk: data)
        let built = ChatRows.build(feed.entries, working: false)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(feed.entries.count, 10_000)
        XCTAssertGreaterThan(built.count, 5_000)
        print("chat-claude: 10k entries, \(data.count) bytes, feed+rows \(Int(elapsed * 1000)) ms")
        #if DEBUG
        XCTAssertLessThan(elapsed, 10.0)
        #else
        XCTAssertLessThan(elapsed, 0.3, "spec: 10k+ entries open in < 300 ms")
        #endif
    }

    /// One appended line on a big transcript: the feed rebuilds every entry each poll.
    func testAppendOneLineToBigTranscriptCost() {
        let lines = (0..<10_000).map { line("assistant", "x\($0)", [["type": "text", "text": "step \($0)"]]) }
        var feed = TimelineFeed(agent: .claude)
        feed.feed(chunk: Data((lines.joined(separator: "\n") + "\n").utf8))
        let start = Date()
        for i in 0..<20 {
            feed.feed(chunk: Data((line("assistant", "y\(i)", [["type": "text", "text": "more"]]) + "\n").utf8))
            _ = ChatRows.build(feed.entries, working: true)
        }
        print("chat-claude: 20 appends on 10k entries \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    // MARK: Real transcripts (opt-in)

    func testRealFixtures() throws {
        guard let dir = ProcessInfo.processInfo.environment["CHAT_CLAUDE_FIXTURES"] else { throw XCTSkip("CHAT_CLAUDE_FIXTURES not set") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jsonl") }.sorted()
        for name in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
            var feed = TimelineFeed(agent: .claude)
            feed.feed(chunk: data)
            // The chat keeps empty (signed-only) thinking lines and tool end times that the phone
            // timeline leaves out; otherwise they agree.
            let chatOnly = feed.entries.filter { !($0.kind == "thinking" && ($0.text ?? "").isEmpty) }
                .map { e -> MobileTimelineEntry in var e = e; e.endTs = nil; return e }
            XCTAssertEqual(chatOnly, ClaudeTimeline.entries(transcript: String(decoding: data, as: UTF8.self)), name)
            XCTAssertEqual(chunked(data), feed.entries, "chunked read differs: \(name)")
            print("chat-claude fixture \(name) model=\(feed.model ?? "-")")
            for row in ChatRows.build(feed.entries, working: false) { print("  " + describe(row)) }
        }
    }

    func testCorpusSweep() throws {
        guard ProcessInfo.processInfo.environment["CHAT_CLAUDE_CORPUS"] != nil else { throw XCTSkip("CHAT_CLAUDE_CORPUS not set") }
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        var all: [(URL, Int)] = []
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        while let url = en?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            all.append((url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        all.sort { $0.1 > $1.1 }
        var rng = SystemRandomNumberGenerator()
        let sample = Array(all.prefix(15)) + Array(all.dropFirst(15).shuffled(using: &rng).prefix(185))
        var stats = CorpusStats()
        for (url, size) in sample {
            guard let data = try? Data(contentsOf: url) else { continue }
            let start = Date()
            var feed = TimelineFeed(agent: .claude)
            feed.feed(chunk: data)
            let rowsBuilt = ChatRows.build(feed.entries, working: false)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if size == sample[0].1 { print("chat-claude corpus largest \(size) bytes, \(feed.entries.count) entries, \(rowsBuilt.count) rows, \(ms) ms") }
            stats.slowest = max(stats.slowest, ms)
            stats.audit(data: data, entries: feed.entries, rows: rowsBuilt, file: url.lastPathComponent)
            if size < 2_000_000, chunked(data) != feed.entries { stats.chunkMismatch.append(url.lastPathComponent) }
        }
        print("chat-claude corpus: \(sample.count) of \(all.count) files")
        stats.report()
    }

    /// Same audit as the sweep, for named files. `CHAT_CLAUDE_FILES=<a.jsonl>:<b.jsonl>`.
    func testCorpusFiles() throws {
        guard let list = ProcessInfo.processInfo.environment["CHAT_CLAUDE_FILES"] else { throw XCTSkip("CHAT_CLAUDE_FILES not set") }
        var stats = CorpusStats()
        for path in list.split(separator: ":").map(String.init) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var feed = TimelineFeed(agent: .claude)
            feed.feed(chunk: data)
            let built = ChatRows.build(feed.entries, working: false)
            let queued = built.filter { if case .user(_, _, true) = $0 { return true }; return false }
            print("chat-claude file \((path as NSString).lastPathComponent): \(feed.entries.count) entries, \(built.count) rows, queued rows \(queued.count)")
            queued.forEach { print("  queued " + describe($0).prefix(200)) }
            stats.audit(data: data, entries: feed.entries, rows: built, file: (path as NSString).lastPathComponent)
        }
        stats.report()
    }

    /// What the app does on open for a big file: read only its last 8 MB (TranscriptFollower.tailBytes)
    /// starting at the first whole line. `CHAT_CLAUDE_TAIL=<file.jsonl>`.
    func testTailOpenOfBigTranscript() throws {
        guard let path = ProcessInfo.processInfo.environment["CHAT_CLAUDE_TAIL"] else { throw XCTSkip("CHAT_CLAUDE_TAIL not set") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let tail = 8 * 1024 * 1024
        let start = Date()
        var from = max(0, data.count - tail)
        if from > 0, let nl = data[from...].firstIndex(of: 0x0A) { from = nl + 1 }
        var feed = TimelineFeed(agent: .claude, offset: from)
        feed.feed(chunk: data.subdata(in: from..<data.count))
        let built = ChatRows.build(feed.entries, working: false)
        print("chat-claude tail-open \(data.count) bytes, read \(data.count - from), \(feed.entries.count) entries, \(built.count) rows, \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    // MARK: Helpers

    /// The file fed in odd-sized pieces, like a poll catching it mid-write.
    func chunked(_ data: Data) -> [MobileTimelineEntry] {
        var feed = TimelineFeed(agent: .claude)
        var end = 0
        var step = 977
        while end < data.count {
            end = min(data.count, end + step)
            feed.feed(chunk: data.subdata(in: feed.offset..<end))
            step = step * 7 % 50_021 + 13
        }
        return feed.entries
    }

    func describe(_ row: ChatRow) -> String {
        func cut(_ s: String) -> String { String(s.replacingOccurrences(of: "\n", with: "⏎").prefix(90)) }
        switch row {
        case .user(_, let t, let q): return "user\(q ? "(queued)" : ""): \(cut(t))"
        case .assistant(_, let t, _): return "assistant: \(cut(t))"
        case .thinking(_, let t): return "thinking: \(cut(t))"
        case .tools(_, let tools, let ms): return "tools[\(tools.count)] \(ChatRows.summary(tools)) \(ms ?? -1)ms"
        case .edit(let e): return "edit \(e.verb) \(e.path) +\(e.additions) -\(e.deletions) lines=\(e.lines.count)"
        case .command(let c): return "command \(c.status) $ \(cut(c.command)) → \(c.summary ?? "-") \(c.durationMs ?? -1)ms"
        case .tool(let t): return "tool \(t.status) \(t.lead) [\(t.verb)] \(cut(t.subject ?? "")) body=\(cut(t.body ?? ""))"
        case .interrupted: return "■ interrupted"
        }
    }
}

/// What the corpus sweep counts.
private struct CorpusStats {
    var topTypes: [String: Int] = [:]
    var userBlocks: [String: Int] = [:]
    var assistantBlocks: [String: Int] = [:]
    var droppedText: [String] = []
    var orphanResults = 0
    var runningInFinished = 0
    var emptyCommand = 0
    var rawTagsInRows: [String] = []
    var toolUses = 0
    var toolRows = 0
    var chunkMismatch: [String] = []
    var slowest = 0
    var emptyThinking = 0
    var leads: [String: Int] = [:]

    mutating func audit(data: Data, entries: [MobileTimelineEntry], rows: [ChatRow], file: String) {
        let ids = Set(entries.map(\.id))
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                topTypes["<unparseable>", default: 0] += 1; continue
            }
            let type = obj["type"] as? String ?? "<none>"
            topTypes[type, default: 0] += 1
            guard type == "user" || type == "assistant", let msg = obj["message"] as? [String: Any] else { continue }
            let uuid = obj["uuid"] as? String ?? ""
            if let blocks = msg["content"] as? [[String: Any]] {
                for (i, b) in blocks.enumerated() {
                    let bt = b["type"] as? String ?? "<none>"
                    if type == "user" { userBlocks[bt, default: 0] += 1 } else { assistantBlocks[bt, default: 0] += 1 }
                    if bt == "tool_use" { toolUses += 1 }
                    if bt == "thinking", (b["thinking"] as? String ?? "").isEmpty { emptyThinking += 1 }
                    // Assistant text that isn't blank must show.
                    if type == "assistant", bt == "text", let t = b["text"] as? String, !t.isBlank,
                       !ids.contains(blocks.count > 1 ? "\(uuid)-\(i)" : uuid), droppedText.count < 15 {
                        droppedText.append("\(file): assistant text dropped: \(t.prefix(60))")
                    }
                }
            } else if type == "user" { userBlocks["<string>", default: 0] += 1 }
        }
        for e in entries where e.kind == "tool" {
            toolRows += 1
            leads[e.lead ?? "<nil>", default: 0] += 1
            if e.lead == "Result" { orphanResults += 1 }
        }
        for (i, row) in rows.enumerated() {
            switch row {
            case .command(let c):
                if c.command.isBlank { emptyCommand += 1 }
                if c.status == .running, i < rows.count - 3 { runningInFinished += 1 }
            case .tool(let t) where t.status == .running && i < rows.count - 3:
                runningInFinished += 1
            case .user(_, let t, _), .assistant(_, let t, _):
                if rawTagsInRows.count < 15, let tag = ["<command-", "<system-reminder", "<local-command", "<task-notification", "<bash-input", "<bash-stdout"].first(where: { t.contains($0) }) {
                    rawTagsInRows.append("\(file): \(tag) in \(row.kindName): \(t.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))")
                }
            default: break
            }
        }
    }

    func report() {
        func top(_ d: [String: Int]) -> String { d.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") }
        print("chat-claude corpus top-level types: \(top(topTypes))")
        print("chat-claude corpus user blocks: \(top(userBlocks))")
        print("chat-claude corpus assistant blocks: \(top(assistantBlocks))")
        print("chat-claude corpus tool_use=\(toolUses) toolRows=\(toolRows) orphanResults=\(orphanResults) runningMidTranscript=\(runningInFinished) emptyCommand=\(emptyCommand) emptyThinking=\(emptyThinking) slowest=\(slowest)ms")
        print("chat-claude corpus leads: \(top(leads))")
        print("chat-claude corpus chunk mismatches: \(chunkMismatch)")
        droppedText.forEach { print("chat-claude corpus DROP " + $0) }
        rawTagsInRows.forEach { print("chat-claude corpus TAG " + $0) }
    }
}
