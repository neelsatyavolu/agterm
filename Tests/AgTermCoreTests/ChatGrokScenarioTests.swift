import XCTest
@testable import AgTermCore

/// Grok chat scenarios end to end: chat_history lines → TimelineFeed → ChatRows. Inline lines are
/// trimmed copies of real Grok 1.0.79 headless runs (`grok -p`); the corpus sweep runs only when
/// `GROK_SWEEP=1` (it reads every `~/.grok/sessions/*/*/chat_history.jsonl`, read-only).
final class ChatGrokScenarioTests: XCTestCase {
    private typealias G = GrokTimelineTests

    private static func rows(_ text: String, working: Bool = false, chunk: Int? = nil) -> [ChatRow] {
        var feed = TimelineFeed(agent: .grok)
        let data = Data(text.utf8)
        if let chunk {
            var start = 0
            while start < data.count {
                let end = min(data.count, start + chunk)
                // Re-offer everything from the feed's offset, as TranscriptFollower does.
                feed.feed(chunk: data.subdata(in: feed.offset..<end))
                start = end
            }
        } else {
            feed.feed(chunk: data)
        }
        return ChatRows.build(feed.entries, working: working)
    }

    private static let preamble = [
        jsonLine(["type": "system", "content": "You are Grok."]),
        G.user("<user_info>\nOS Version: macos\nWorkspace Path: /w\n</user_info>\n\n<rules>\nbe nice\n</rules>"),
        G.user("<system-reminder>\nThe following skills are available\n</system-reminder>"),
    ]

    private static func session(_ query: String, _ lines: [String]) -> String {
        (preamble + [G.user("<user_query>\n\(query)\n</user_query>", extra: ["prompt_index": 0]),
                     G.user("<system-reminder>\nMCP servers currently connecting\n</system-reminder>")] + lines)
            .joined(separator: "\n") + "\n"
    }

    private static func reasoning(_ text: String?) -> String {
        jsonLine(["type": "reasoning", "id": "rs", "status": "completed", "encrypted_content": "x",
                  "summary": text.map { [["type": "summary_text", "text": $0]] } ?? []])
    }

    // MARK: Real headless runs

    func testPlainReply() {
        let rows = Self.rows(Self.session("Reply with exactly: hello there",
                                          [Self.reasoning("Preparing to reply."), G.assistant("hello there")]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "thinking", "assistant"])
        XCTAssertEqual(rows.first, .user(id: rows[0].id, text: "Reply with exactly: hello there", queued: false))
        XCTAssertEqual(rows.last, .assistant(id: rows[2].id, text: "hello there", streaming: false))
    }

    func testMarkdownReplyKeepsFences() {
        let md = "## Plan\n\n- a\n- b\n- c\n\n```python\nprint(\"hi\")\n```\n\n~~~\n```nested```\n~~~"
        let rows = Self.rows(Self.session("markdown", [G.assistant(md)]))
        guard case .assistant(_, let text, _)? = rows.last else { return XCTFail("\(rows)") }
        XCTAssertEqual(text, md)
        let lines = ChatText.lines(text)
        XCTAssertEqual(lines.first, .heading([ChatSpan(.plain, "Plan")]))
        XCTAssertEqual(lines.filter { if case .bullet = $0 { return true } else { return false } }.count, 3)
        XCTAssertTrue(lines.contains(.code(["print(\"hi\")"])))
        XCTAssertTrue(lines.contains(.code(["```nested```"])), "\(lines)")
    }

    func testReadAndListFoldIntoOneLine() {
        let rows = Self.rows(Self.session("Read notes.txt", [
            Self.reasoning(nil),
            G.assistant("I'll read `notes.txt` and list the directory.",
                        [G.call("c-0", "read_file", ["target_file": "/w/notes.txt"]),
                         G.call("c-1", "list_dir", ["target_directory": "/w"])]),
            G.result("c-0", "1→alpha\nbeta\ngamma\n"),
            G.result("c-1", "- /w/\n  - notes.txt"),
            G.user("<system-reminder>\nContext from PreToolUse hook\n</system-reminder>"),
            G.assistant("The second line is `beta`."),
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant", "tools", "assistant"])
        guard case .tools(_, let tools, _) = rows[2] else { return XCTFail() }
        XCTAssertEqual(tools.map(\.verb), ["Read", "List"])
        XCTAssertEqual(ChatRows.summary(tools), "Read w/notes.txt · List w")
    }

    func testSearchReplaceAndCreateBecomeEditCards() {
        let rows = Self.rows(Self.session("edit", [
            G.assistant("", [G.call("c-1", "search_replace", ["file_path": "/w/f.txt", "old_string": "line two", "new_string": "LINE 2"]),
                             G.call("c-2", "search_replace", ["file_path": "/w/new.txt", "old_string": "", "new_string": "x"])]),
            // Real order: results came back in reverse.
            G.result("c-2", "The file /w/new.txt has been created successfully."),
            G.result("c-1", "The file /w/f.txt has been updated successfully."),
            G.assistant("Updated."),
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "edit", "edit", "assistant"])
        guard case .edit(let a) = rows[1], case .edit(let b) = rows[2] else { return XCTFail() }
        XCTAssertEqual(a.status, .ok)
        XCTAssertEqual(a.lines.filter { $0.kind == .removed }.map(\.text), ["line two"])
        XCTAssertEqual(a.lines.filter { $0.kind == .added }.map(\.text), ["LINE 2"])
        XCTAssertEqual(b.lines.filter { $0.kind == .added }.map(\.text), ["x"])
        XCTAssertEqual(b.lines.filter { $0.kind == .removed }.count, 0)
    }

    func testFailingCommandIsADangerRow() {
        let rows = Self.rows(Self.session("ls", [
            G.assistant("I'll run that command exactly, then reply.",
                        [G.call("c-0", "run_terminal_command", ["command": "ls /nonexistent-dir-xyz", "description": "List"])]),
            G.result("c-0", "exit: 1\nls: /nonexistent-dir-xyz: No such file or directory\n"),
            G.assistant("done"),
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant", "command", "assistant"])
        guard case .command(let c) = rows[2] else { return XCTFail() }
        XCTAssertEqual(c.status, .error)
        XCTAssertEqual(c.command, "ls /nonexistent-dir-xyz")
        XCTAssertEqual(c.errorLines.first, "ls: /nonexistent-dir-xyz: No such file or directory")
        XCTAssertFalse((c.output ?? "").contains("exit: 1"))
    }

    func testCommandThatExitsZeroButPrintsAnErrorIsOk() {
        // Real: Grok wrapped the command with `; echo EXIT_CODE:$?`, so the shell exited 0.
        let rows = Self.rows(Self.session("ls", [
            G.assistant("", [G.call("c-0", "run_terminal_command", ["command": "ls /x ; echo \"EXIT_CODE:$?\""])]),
            G.result("c-0", "exit: 0\nls: /x: No such file or directory\nEXIT_CODE:1\n"),
        ]))
        guard case .command(let c)? = rows.last else { return XCTFail("\(rows)") }
        XCTAssertEqual(c.status, .ok)
        XCTAssertEqual(c.summary, "ls: /x: No such file or directory")
    }

    func testLongCommandOutputIsCapped() {
        let out = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let rows = Self.rows(Self.session("ls", [
            G.assistant("", [G.call("c-0", "run_terminal_command", ["command": "seq 5000"])]),
            G.result("c-0", "exit: 2\n" + out),
        ]))
        guard case .command(let c)? = rows.last else { return XCTFail() }
        XCTAssertEqual(c.status, .error)
        XCTAssertEqual(c.errorLines.count, ChatRows.errorPreviewLines)
        XCTAssertLessThan((c.output ?? "").utf8.count, out.utf8.count, "giant output should be cut")
    }

    // MARK: Situations from the corpus

    func testRunningToolThenFinishedInALaterChunk() {
        let head = Self.session("go", [G.assistant("", [G.call("c-0", "run_terminal_command", ["command": "sleep 5"])])])
        guard case .command(let running)? = Self.rows(head, working: true).last else { return XCTFail() }
        XCTAssertEqual(running.status, .running)
        let full = head + G.result("c-0", "exit: 0\n") + "\n"
        guard case .command(let c)? = Self.rows(full).last else { return XCTFail() }
        XCTAssertEqual(c.status, .ok)
    }

    func testStreamingCursorOnLastReplyWhileWorking() {
        let rows = Self.rows(Self.session("hi", [G.assistant("partial")]), working: true)
        XCTAssertEqual(rows.last, .assistant(id: rows.last!.id, text: "partial", streaming: true))
    }

    func testToolErrorShapes() {
        let rows = Self.rows(Self.session("x", [
            G.assistant("", [G.call("c-0", "search_replace", ["file_path": "/w/a", "old_string": "nope", "new_string": "y"]),
                             G.call("c-1", "read_file", ["target_file": "/w/missing"])]),
            G.result("c-0", "The string to replace was not found in the file."),
            G.result("c-1", "Error: file not found"),
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "tool", "tool"])
        for row in rows.dropFirst() {
            guard case .tool(let t) = row else { return XCTFail() }
            XCTAssertEqual(t.status, .error)
        }
    }

    func testSubagentWebAndMCPTools() {
        let rows = Self.rows(Self.session("x", [
            G.assistant("", [G.call("c-0", "spawn_subagent", ["description": "explore", "prompt": "look"]),
                             G.call("c-1", "web_fetch", ["url": "https://example.com"]),
                             G.call("c-2", "use_tool", ["tool_name": "mcp__consult__ask_agent", "tool_input": ["q": "hi"]]),
                             G.call("c-3", "brand_new_tool", ["a": 1])]),
            G.result("c-0", "done"), G.result("c-1", "<html>"), G.result("c-2", "ok"), G.result("c-3", "ok"),
            jsonLine(["type": "backend_tool_call", "kind": ["tool_type": "web_search", "action": ["query": "swift"]]]),
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "tool", "tool", "tool", "tool", "tool"])
        let tools = rows.compactMap { row -> ChatTool? in if case .tool(let t) = row { return t } else { return nil } }
        XCTAssertTrue(tools.allSatisfy { $0.status == .ok && !$0.lead.isEmpty })
        XCTAssertEqual(tools[1].subject, "https://example.com")
        XCTAssertEqual(tools[4].subject, "swift")
    }

    func testImagesInterruptAndInterjection() {
        let image = jsonLine(["type": "user", "prompt_index": 1, "content": [
            ["type": "text", "text": "<user_query>\nwhat is this\n</user_query>"],
            ["type": "image", "source": ["data": "AAAA"]]]])
        let rows = Self.rows(Self.session("first", [
            G.assistant("", [G.call("c-0", "run_terminal_command", ["command": "sleep 100"])]),
            G.user("<user_query>\nstop\n</user_query>", extra: ["prior_turn_interrupt": true, "prompt_index": 1]),
            G.user("also this", extra: ["synthetic_reason": "interjection"]),
            image,
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "command", "interrupted", "user", "user", "user"])
        guard case .user(_, let text, _) = rows.last! else { return XCTFail() }
        XCTAssertEqual(text, "what is this\n[Image #1]")
    }

    func testCompactionAndTaskNoticesAreHidden() {
        let rows = Self.rows(Self.session("x", [
            G.user("summary of earlier work", extra: ["synthetic_reason": "compaction_meta"]),
            G.user("task done", extra: ["synthetic_reason": "task_completed"]),
            G.user("subagent done", extra: ["synthetic_reason": "subagent_completed"]),
            G.user("hook says no", extra: ["synthetic_reason": "stop_hook_feedback"]),
            G.assistant("ok"),
        ]))
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant"])
    }

    func testUnicodeLongLinesUnknownAndMalformed() {
        let weird = "中文 😀👩‍👩‍👧 עברית e\u{301} " + String(repeating: "x", count: 20_000)
        let text = Self.session(weird, [
            jsonLine(["type": "brand_new_kind", "content": "?"]),
            "{not json",
            G.assistant(weird),
        ])
        let rows = Self.rows(text)
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant"])
        XCTAssertEqual(rows.last, .assistant(id: rows.last!.id, text: weird, streaming: false))
        // Byte-wise chunking (splitting multi-byte characters) gives the same rows.
        XCTAssertEqual(Self.rows(text, chunk: 7), rows)
    }

    func testTruncatedLastLineAndEmpty() {
        XCTAssertEqual(Self.rows(""), [])
        let full = Self.session("hi", [G.assistant("hello")])
        let cut = String(full.dropLast(10))
        XCTAssertEqual(Self.rows(cut).map(\.kindName), ["user"])
    }

    func testTenThousandEntriesOpenFast() {
        var lines: [String] = []
        for i in 0..<3500 {
            lines.append(G.assistant("step \(i)", [G.call("c\(i)", "read_file", ["target_file": "/w/f\(i)"])]))
            lines.append(G.result("c\(i)", "1→x"))
            lines.append(Self.reasoning("thinking \(i)"))
        }
        let text = Self.session("big", lines)
        let start = Date()
        let rows = Self.rows(text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(rows.count, 10_000)
        #if DEBUG
        let limit = 1.0  // unoptimized build; release measured ~0.1s
        #else
        let limit = 0.3
        #endif
        XCTAssertLessThan(elapsed, limit, "parse + rows took \(elapsed)s")
    }

    // MARK: Screens (captured from Grok 1.0.79 in a 120x40 pty, `--permission-mode default`)

    static let approvalScreen = [
        "   ◆ Remove made-by-grok.txt if present… 31s                                                      37s ⇣65.2k [↓][stop]",
        "  ┃",
        "  ┃  ›  Remove made-by-grok.txt if present",
        "  ┃  │ rm -f made-by-grok.txt",
        "  ┃  ← → narrow scope  ·  e edit pattern",
        "  ┃",
        "  ┃  Auto-review blocked this action.  Ctrl-F to view explanation",
        "  ┃",
        "  ┃  1 (○) Yes, and don't ask again for anything (always-approve mode)",
        "  ┃  2 (○) Always allow: rm -f made-by-grok.txt",
        "  ┃  3 (●) Yes, proceed",
        "  ┃  4 (○) No, reject (type to add feedback)",
        "  ┃  5 (○) Never allow: rm -f",
        "  ┃",
        "  1/5:select  │  Tab:next option  │  ←/→:scope  │  e:edit pattern  │  Ctrl+f:expand  │  Ctrl+o:always-approve",
    ]

    /// `/goal` wraps the goal in harness instructions; the user row shows only the goal.
    func testGoalCommandShowsTheGoalNotTheReminder() {
        let text = "<user_query>\n<system-reminder>\nA goal has been set: make the benchmarks hard\n\nYou are working directly on this goal across multiple turns.\n\nStart now.\n</system-reminder>\n\n\n</user_query>"
        XCTAssertEqual(GrokTimeline.userQuery(text), "Goal: make the benchmarks hard")
        XCTAssertEqual(GrokTimeline.userQuery("<user_query>\n<system-reminder>x</system-reminder>\n</user_query>"), nil)
        XCTAssertEqual(GrokTimeline.userQuery("<user_query>hi</user_query>"), "hi")
    }

    /// Grok's tool approval should become the chat's approval card with five answers.
    func testGrokApprovalPromptIsRead() {
        let prompt = PermissionPrompt.read(Self.approvalScreen)
        XCTAssertNotNil(prompt, "Grok's `N (●) label` approval shape isn't recognised")
        XCTAssertEqual(prompt?.choices.count, 5)
        XCTAssertEqual(prompt?.question, "Remove made-by-grok.txt if present")
        XCTAssertEqual(prompt?.choices.map(\.key), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(prompt?.choices.first { $0.selected }?.label, "Yes, proceed")
        XCTAssertTrue(PermissionPrompt.isVisible(Self.approvalScreen), "so the tab counts as waiting, not working")
    }

    /// The first-run folder trust question has no numbers: the chat shows it as a screen excerpt.
    func testGrokTrustPromptFallsBackToTheScreenExcerpt() {
        let screen = ["", "                                      Do you trust the contents of this directory?",
                      "                                 /private/tmp/x", "",
                      "                                Grok Build may run or modify contents in this directory,",
                      "                                                 posing security risks.", "",
                      "                                             Yes, proceed                 y",
                      "                                             No, quit                     n", "", "", "",
                      "                                                                                            Grok Build  1.0.79 [alpha]"]
        XCTAssertNil(PermissionPrompt.read(screen))
        let excerpt = ChatRows.screenExcerpt(screen)
        XCTAssertTrue(excerpt.contains { $0.contains("Do you trust") })
        XCTAssertTrue(excerpt.contains { $0.contains("No, quit") })
    }

    // MARK: Real files (optional)

    /// The headless runs under /private/tmp/claude-503/agterm-chat-tests/grok-*, when present.
    func testGeneratedSessionsWhenPresent() throws {
        let sessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
        let expected: [String: [String]] = [
            "grok-plain": ["user", "thinking", "assistant"],
            "grok-md": ["user", "thinking", "assistant"],
            "grok-read": ["user", "assistant", "tools", "assistant"],
            "grok-edit": ["user", "thinking", "tools", "edit", "edit", "thinking", "assistant"],
            "grok-fail2": ["user", "assistant", "command", "assistant"],
        ]
        var checked = 0
        for (name, kinds) in expected {
            let cwd = "/private/tmp/claude-503/agterm-chat-tests/\(name)"
            guard let id = GrokSessions.latest(in: sessions, cwd: cwd, since: .distantPast),
                  let file = GrokSessions.chatHistory(in: sessions, cwd: cwd, sessionID: id),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            checked += 1
            let rows = Self.rows(text)
            XCTAssertEqual(rows.map(\.kindName), kinds, name)
            XCTAssertEqual(Self.rows(text, chunk: 997), rows, "\(name) chunked")
            XCTAssertFalse(rows.contains { if case .user(_, let t, _) = $0 { return t.contains("<") } else { return false } },
                           "\(name): plumbing leaked into a user row")
        }
        if checked == 0 { throw XCTSkip("no generated sessions") }
    }

    /// Every chat_history in ~/.grok/sessions: no crash, no leaks, ids unique, chunked == whole,
    /// every tool call has a row, and the time each took.
    func testCorpusSweep() throws {
        guard ProcessInfo.processInfo.environment["GROK_SWEEP"] == "1" else { throw XCTSkip("set GROK_SWEEP=1") }
        let fm = FileManager.default
        let sessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
        var report: [String] = []
        var files = 0, totalEntries = 0, slowest = (0.0, ""), unknownKinds = Set<String>()
        var leakedUsers = 0, missingTools = 0, runningMidFile = 0, orphanResults = 0, dupIDs = 0, chunkMismatch = 0
        var wrongLatest = 0
        for folder in (try? fm.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            let dir = sessions.appendingPathComponent(folder)
            guard let ids = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            var newest: (String, Date)?
            for id in ids {
                let file = dir.appendingPathComponent(id).appendingPathComponent("chat_history.jsonl")
                guard let data = fm.contents(atPath: file.path) else { continue }
                let mod = ["chat_history.jsonl", "events.jsonl"].compactMap {
                    (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(id).appendingPathComponent($0).path))?[.modificationDate] as? Date
                }.max()
                if let mod, mod > (newest?.1 ?? .distantPast) { newest = (id, mod) }
                files += 1
                let start = Date()
                var feed = TimelineFeed(agent: .grok)
                feed.feed(chunk: data)
                let rows = ChatRows.build(feed.entries, working: false)
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > slowest.0 { slowest = (elapsed, "\(folder)/\(id) \(data.count)B \(feed.entries.count) entries") }
                totalEntries += feed.entries.count
                let entries = feed.entries
                for e in entries where !["user", "assistant", "thinking", "tool", "interrupted"].contains(e.kind) { unknownKinds.insert(e.kind) }
                if Set(entries.map(\.id)).count != entries.count { dupIDs += 1; report.append("dup ids: \(file.path)") }
                if Set(rows.map(\.id)).count != rows.count { dupIDs += 1; report.append("dup row ids: \(file.path)") }
                for row in rows {
                    if case .user(_, let t, _) = row, t.contains("<system-reminder>") || t.contains("<user_info>") || t.contains("<rules>") {
                        leakedUsers += 1
                        if leakedUsers <= 5 { report.append("leak: \(file.lastPathComponent) \(folder)/\(id): \(t.prefix(120))") }
                    }
                }
                // Independent count of tool calls and results.
                var calls = 0, results: [String] = [], callIDs = Set<String>()
                for line in data.split(separator: 0x0A) {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if obj["type"] as? String == "assistant", let tc = obj["tool_calls"] as? [[String: Any]] {
                        calls += tc.count
                        tc.compactMap { $0["id"] as? String }.forEach { callIDs.insert($0) }
                    }
                    if obj["type"] as? String == "tool_result", let id = obj["tool_call_id"] as? String { results.append(id) }
                }
                let toolEntries = entries.filter { $0.kind == "tool" && $0.lead != "Result" && $0.toolName != "web_search" && $0.toolName != "x_search" }
                if toolEntries.count != calls {
                    missingTools += 1
                    report.append("tools \(toolEntries.count) != calls \(calls): \(folder)/\(id)")
                }
                let orphans = entries.filter { $0.lead == "Result" }.count
                let expectedOrphans = results.filter { !callIDs.contains($0) }.count
                if orphans != expectedOrphans { orphanResults += 1; report.append("orphans \(orphans) vs \(expectedOrphans): \(folder)/\(id)") }
                // A running tool before the last user turn means a result was missed.
                if let lastUser = entries.lastIndex(where: { $0.kind == "user" }) {
                    let stuck = entries[..<lastUser].filter { $0.status == "running" }
                    if !stuck.isEmpty {
                        runningMidFile += 1
                        if runningMidFile <= 8 { report.append("running before last turn (\(stuck.count), \(stuck.first!.toolName ?? "?")): \(folder)/\(id)") }
                    }
                }
                if data.count < 3_000_000 {
                    var chunked = TimelineFeed(agent: .grok)
                    var pos = 0
                    while pos < data.count {
                        let end = min(data.count, pos + 4093)
                        chunked.feed(chunk: data.subdata(in: chunked.offset..<end))
                        pos = end
                    }
                    if chunked.entries != entries { chunkMismatch += 1; report.append("chunk mismatch: \(folder)/\(id)") }
                }
            }
            if let path = folder.removingPercentEncoding, let newest {
                let picked = GrokSessions.latest(in: sessions, cwd: path, since: .distantPast)
                if picked != newest.0 { wrongLatest += 1; report.append("latest \(picked ?? "nil") != \(newest.0) for \(path)") }
            }
        }
        report.insert("""
            files=\(files) entries=\(totalEntries) unknownKinds=\(unknownKinds.sorted()) leakedUsers=\(leakedUsers) \
            toolMismatch=\(missingTools) orphanMismatch=\(orphanResults) runningMidFile=\(runningMidFile) \
            dupIDs=\(dupIDs) chunkMismatch=\(chunkMismatch) wrongLatest=\(wrongLatest) \
            slowest=\(String(format: "%.3f", slowest.0))s \(slowest.1)
            """, at: 0)
        let out = report.joined(separator: "\n")
        print("grok-sweep:\n" + out)
        try? out.write(toFile: "/private/tmp/claude-503/agterm-chat-tests/grok-sweep.txt", atomically: true, encoding: .utf8)
    }
}

/// Recheck: which conversation a Grok chat follows. `locate` mirrors the decision in
/// TranscriptFollower.locateGrok (app target, private), run against a scratch sessions folder.
final class ChatGrokLocateScenarioTests: XCTestCase {
    private var root: URL!
    private let cwd = "/private/tmp/claude-503/agterm-chat-tests/grok-locate-cwd"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ id: String, created: Date, modified: Date) throws {
        let folder = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let dir = root.appendingPathComponent(folder).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("chat_history.jsonl")
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: dir.path)
    }

    /// What TranscriptFollower.locateGrok asks `GrokSessions.follow`, with `others` = other agterm
    /// tabs' launch ids and `typing` = when typing in this tab stopped.
    private func locate(own grokSession: String?, since start: Date, others: Set<String>, typing: [Date] = [],
                        following: String? = nil) -> String? {
        GrokSessions.follow(in: root, cwd: cwd, own: grokSession, since: start.addingTimeInterval(-5), others: others,
                            inputs: typing, following: following)
    }

    func testLaunchKnowsResumedAndNamedSessions() {
        XCTAssertEqual(GrokSessions.launch(["--resume", "abc12345"]) { "new" }.sessionID, "abc12345")
        XCTAssertEqual(GrokSessions.launch(["-r", "abc12345"]) { "new" }.sessionID, "abc12345")
        XCTAssertEqual(GrokSessions.launch(["--resume=abc12345"]) { "new" }.sessionID, "abc12345")
        XCTAssertEqual(GrokSessions.launch([]) { "new" }.sessionID, "new")
        XCTAssertNil(GrokSessions.launch(["-c"]) { "new" }.sessionID, "--continue: agterm can't tell which conversation")
        XCTAssertNil(GrokSessions.launch(["--resume"]) { "new" }.sessionID, "bare --resume opens a picker")
    }

    func testResumedOldSessionShowsItsHistoryBeforeAnyWrite() throws {
        let old = Date().addingTimeInterval(-3600), start = Date()
        try write("old-session-1", created: old, modified: old)
        XCTAssertEqual(locate(own: "old-session-1", since: start, others: []), "old-session-1")
    }

    func testContinueWithNothingWrittenYetFindsNothing() throws {
        let old = Date().addingTimeInterval(-3600), start = Date()
        try write("old-session-1", created: old, modified: old)
        XCTAssertNil(locate(own: nil, since: start, others: []))
    }

    func testOtherAgtermTabInSameFolderIsIgnored() throws {
        let start = Date().addingTimeInterval(-60)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(10))
        try write("tab-b-0001", created: start.addingTimeInterval(5), modified: Date())
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001", "tab-b-0001"]), "tab-a-0001")
    }

    func testOwnNewConversationIsFollowed() throws {
        let start = Date().addingTimeInterval(-60)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(10))
        try write("tab-a-new1", created: start.addingTimeInterval(20), modified: Date())
        // `/new` and the prompt were typed in this tab just before the conversation was made.
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001"], typing: [start.addingTimeInterval(19)]), "tab-a-new1")
    }

    func testOwnNewConversationStaysFollowedAfterMoreTyping() throws {
        let start = Date().addingTimeInterval(-600)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(10))
        try write("tab-a-new1", created: start.addingTimeInterval(20), modified: Date())
        // Its typing stop has scrolled out of the window kept, but the chat already shows it.
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001"], typing: [start.addingTimeInterval(500)],
                              following: "tab-a-new1"), "tab-a-new1")
    }

    func testNewConversationLongAfterTypingIsNotFollowed() throws {
        let start = Date().addingTimeInterval(-600)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(10))
        try write("outside-new", created: start.addingTimeInterval(300), modified: Date())
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001"],
                              typing: [start.addingTimeInterval(15), start.addingTimeInterval(400)]), "tab-a-0001")
    }

    /// `grok -c` reopens the conversation in the folder written last; agterm records it at launch.
    func testContinueRecordsTheNewestConversation() throws {
        let old = Date().addingTimeInterval(-3600)
        try write("older-0001", created: old, modified: old)
        try write("newer-0001", created: old, modified: old.addingTimeInterval(60))
        XCTAssertEqual(GrokSessions.continued(["-c"], in: root, cwd: cwd), "newer-0001")
        XCTAssertEqual(GrokSessions.continued(["--continue", "fix it"], in: root, cwd: cwd), "newer-0001")
        XCTAssertNil(GrokSessions.continued(["-c", "--fork-session"], in: root, cwd: cwd))
        XCTAssertNil(GrokSessions.continued([], in: root, cwd: cwd))
        // With that id, the continued conversation shows before anything is written to it.
        XCTAssertEqual(locate(own: "newer-0001", since: Date(), others: []), "newer-0001")
    }

    func testOldConversationWrittenElsewhereIsIgnored() throws {
        let start = Date().addingTimeInterval(-60), old = Date().addingTimeInterval(-3600)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(10))
        try write("outside-old", created: old, modified: Date())
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001"]), "tab-a-0001")
    }

    /// Residual: a new conversation started outside agterm (or by `/new` in another agterm tab)
    /// in the same folder looks the same as this tab's own `/new`.
    func testNewConversationStartedOutsideAgtermIsNotFollowed() throws {
        let start = Date().addingTimeInterval(-60)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(10))
        try write("outside-new", created: start.addingTimeInterval(30), modified: Date())
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001"]), "tab-a-0001")
    }
}

extension ChatGrokScenarioTests {
    /// The recheck run: read + search_replace + failing `ls` + markdown reply, in one session.
    func testRecheckRunWhenPresent() throws {
        let sessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
        let cwd = "/private/tmp/claude-503/agterm-chat-tests/grok-recheck"
        guard let id = GrokSessions.latest(in: sessions, cwd: cwd, since: .distantPast),
              let file = GrokSessions.chatHistory(in: sessions, cwd: cwd, sessionID: id),
              let text = try? String(contentsOf: file, encoding: .utf8) else { throw XCTSkip("no recheck run") }
        var feed = TimelineFeed(agent: .grok)
        feed.feed(chunk: Data(text.utf8))
        let rows = ChatRows.build(feed.entries, working: false)
        print("grok-recheck rows: \(rows.map(\.kindName))")
        XCTAssertEqual(rows.first?.kindName, "user")
        guard case .user(_, let q, _)? = rows.first else { return XCTFail() }
        XCTAssertTrue(q.hasPrefix("Read notes.txt"), q)
        let commands = rows.compactMap { r -> ChatCommand? in if case .command(let c) = r { return c } else { return nil } }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.status, .error)
        XCTAssertEqual(commands.first?.errorLines.first, "ls: /nonexistent-xyz-recheck: No such file or directory")
        let edits = rows.compactMap { r -> ChatEdit? in if case .edit(let e) = r { return e } else { return nil } }
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.lines.filter { $0.kind == .added }.map(\.text), ["TWO"])
        guard case .assistant(_, let reply, _)? = rows.last else { return XCTFail("\(rows)") }
        XCTAssertTrue(ChatText.lines(reply).contains(.code(["one", "TWO", "three"])), reply)
    }
}

extension ChatGrokScenarioTests {
    /// A second live capture (grok-approve2): the screen just before pressing `4`, which rejected at once.
    func testLiveApprovalCaptureWhenPresent() throws {
        let url = URL(fileURLWithPath: "/private/tmp/claude-503/agterm-chat-tests/grok-approve2/key4.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let before = obj["before"] as? [String], let after = obj["after"] as? [String] else { throw XCTSkip("no capture") }
        let prompt = PermissionPrompt.read(before)
        XCTAssertEqual(prompt?.choices.count, 5)
        XCTAssertEqual(prompt?.choices.map(\.key), ["1", "2", "3", "4", "5"])
        XCTAssertTrue(prompt?.question?.contains("made-by-grok.txt") ?? false, "\(String(describing: prompt?.question))")
        XCTAssertTrue(PermissionPrompt.isVisible(before))
        XCTAssertFalse(PermissionPrompt.isVisible(after), "after the key the prompt is gone")
        XCTAssertNil(PermissionPrompt.read(after))
    }
}

extension ChatGrokScenarioTests {
    /// The real `/goal` turn from the corpus that leaked a system-reminder before the fix.
    func testRealGoalTurnWhenPresent() throws {
        let path = NSHomeDirectory() + "/.grok/sessions/%2FUsers%2Fneel%2FDocuments%2FGitHub/01a0bf88-04dd-71f2-9f44-26e5440a8fd9/chat_history.jsonl"
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("no goal session") }
        var feed = TimelineFeed(agent: .grok)
        feed.feed(chunk: data)
        let users = ChatRows.build(feed.entries, working: false).compactMap { r -> String? in
            if case .user(_, let t, _) = r { return t } else { return nil }
        }
        let goal = users.first { $0.hasPrefix("Goal: ") }
        print("grok goal row: \(goal.map { String($0.prefix(160)) } ?? "nil") (\(goal?.utf8.count ?? 0) bytes)")
        XCTAssertNotNil(goal, "\(users.map { $0.prefix(80) })")
        XCTAssertTrue(goal?.contains("I want to redesign my benchmarks") ?? false)
        XCTAssertFalse(users.contains { $0.contains("system-reminder") || $0.contains("Start now.") })
    }
}

extension ChatGrokLocateScenarioTests {
    /// Recheck residual: tab A is mid-conversation (typed at +25 s, and its own grok answered at
    /// +28 s), then a `grok -p` run elsewhere in the same folder (a script, another agent's
    /// consult call) starts a new conversation at +30 s. Typing in tab A was answered by its own
    /// conversation, so the new one isn't this tab's `/new`.
    func testOutsideRunWhileThisTabIsChattingIsNotFollowed() throws {
        let start = Date().addingTimeInterval(-60)
        try write("tab-a-0001", created: start, modified: start.addingTimeInterval(28))
        try write("outside-p", created: start.addingTimeInterval(30), modified: Date())
        XCTAssertEqual(locate(own: "tab-a-0001", since: start, others: ["tab-a-0001"], typing: [start.addingTimeInterval(25)]),
                       "tab-a-0001")
    }

    /// Bare `--resume` opens a picker; nothing is written when one is picked, so nothing is found
    /// until the first message is sent.
    func testBareResumePickerFindsNothingBeforeFirstMessage() throws {
        let old = Date().addingTimeInterval(-3600), start = Date()
        try write("picked-0001", created: old, modified: old)
        XCTAssertNil(GrokSessions.launch(["--resume"]) { "new" }.sessionID)
        XCTAssertNil(GrokSessions.continued(["--resume"], in: root, cwd: cwd))
        XCTAssertNil(locate(own: nil, since: start, others: []), "known limit: picker choice is invisible until a write")
    }
}

extension ChatGrokLocateScenarioTests {
    /// Real runs in grok-cont: A, then B, then `grok -r A -p` (A written last), then `grok -c -p`,
    /// which grok appended to A. `continued` must name A, the one `-c` reopened.
    func testRealContinuePicksTheConversationGrokReopenedWhenPresent() throws {
        let sessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
        let cwd = "/private/tmp/claude-503/agterm-chat-tests/grok-cont"
        let a = "01a1bd62-649a-7cb3-ba99-40881de71daa"
        guard let file = GrokSessions.chatHistory(in: sessions, cwd: cwd, sessionID: a),
              let text = try? String(contentsOf: file, encoding: .utf8), text.contains("exactly: C") else { throw XCTSkip("no grok-cont run") }
        XCTAssertEqual(GrokSessions.continued(["-c"], in: sessions, cwd: cwd), a)
        XCTAssertEqual(GrokSessions.follow(in: sessions, cwd: cwd, own: a, since: Date(), others: [], inputs: []), a)
    }
}
