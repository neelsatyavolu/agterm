import XCTest
@testable import AgTermCore

extension Array where Element == ChatRow {
    /// Folded command runs as one `.command` row each, for tests about what a command row holds.
    var unfolded: [ChatRow] {
        flatMap { row -> [ChatRow] in
            if case let .commands(_, commands, _) = row { return commands.map { .command($0) } }
            return [row]
        }
    }
}

/// Timeline entries grouped into the rows the chat view paints.
final class ChatRowsTests: XCTestCase {
    func user(_ id: String, _ text: String, state: String? = nil, ts: Int = 0) -> MobileTimelineEntry {
        MobileTimelineEntry(id: id, kind: "user", text: text, state: state, ts: ts)
    }

    func text(_ id: String, _ kind: String, _ text: String, ts: Int = 0) -> MobileTimelineEntry {
        MobileTimelineEntry(id: id, kind: kind, text: text, ts: ts)
    }

    func tool(_ id: String, lead: String, name: String, subject: String? = nil, status: String = "ok", body: String? = nil,
              additions: Int? = nil, deletions: Int? = nil, ts: Int = 0) -> MobileTimelineEntry {
        MobileTimelineEntry(id: id, kind: "tool", lead: lead, subject: subject, status: status, additions: additions,
                            deletions: deletions, body: body, toolName: name, ts: ts)
    }

    func testPlainTurn() {
        let rows = ChatRows.build([user("u", "hi"), text("a", "assistant", "Hello **there**")], working: false)
        XCTAssertEqual(rows, [.user(id: "u", text: "hi", queued: false), .assistant(id: "a", text: "Hello **there**", streaming: false)])
        XCTAssertEqual(rows.map(\.id), ["u", "a"])
    }

    func testStreamingCursorOnlyOnTheLastReplyWhileWorking() {
        let entries = [user("u", "hi"), text("a", "assistant", "Part")]
        XCTAssertEqual(ChatRows.build(entries, working: true).last, .assistant(id: "a", text: "Part", streaming: true))
        let withTool = entries + [tool("t", lead: "Ran", name: "Bash", subject: "make", status: "running")]
        XCTAssertEqual(ChatRows.build(withTool, working: true)[1], .assistant(id: "a", text: "Part", streaming: false))
    }

    func testThinking() {
        XCTAssertEqual(ChatRows.build([text("th", "thinking", "Consider X")], working: false), [.thinking(id: "th", text: "Consider X")])
    }

    func testConsecutiveFinishedReadsFoldIntoOneRow() throws {
        let rows = ChatRows.build([
            tool("r1", lead: "Read", name: "Read", subject: "Sources/a.swift", ts: 1_000),
            tool("g1", lead: "Searched", name: "Grep", subject: "TODO", ts: 1_200),
            tool("l1", lead: "Searched", name: "list_dir", subject: "w/ops", ts: 1_300),
            tool("gl", lead: "Searched", name: "Glob", subject: "**/*.md", ts: 1_400),
            text("a", "assistant", "Found it.", ts: 1_600),
        ], working: false)
        XCTAssertEqual(rows.count, 2)
        guard case let .tools(id, tools, duration) = rows[0] else { return XCTFail("\(rows[0])") }
        XCTAssertEqual(id, "group:r1")
        XCTAssertEqual(tools.map(\.id), ["r1", "g1", "l1", "gl"])
        XCTAssertEqual(duration, 600)
        XCTAssertEqual(ChatRows.summary(tools), #"Read Sources/a.swift · Grep "TODO" · List w/ops · Glob **/*.md"#)
    }

    func testRunningOrFailedReadBreaksTheFold() {
        let rows = ChatRows.build([
            tool("r1", lead: "Read", name: "Read", subject: "a"),
            tool("r2", lead: "Read", name: "Read", subject: "b", status: "error", body: "Error: no such file"),
            tool("r3", lead: "Read", name: "Read", subject: "c"),
            tool("r4", lead: "Read", name: "Read", subject: "d", status: "running"),
        ], working: true)
        XCTAssertEqual(rows.map(\.id), ["group:r1", "r2", "group:r3", "r4"])
        guard case let .tool(failed) = rows[1], case let .tool(running) = rows[3] else { return XCTFail("\(rows)") }
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(running.status, .running)
    }

    func testEditCardCapsDiffLines() throws {
        let body = "@@ -1,2 +1,20 @@\n-old one\n-old two\n" + (1...20).map { "+new \($0)" }.joined(separator: "\n") + "\n"
        let rows = ChatRows.build([tool("e", lead: "Edited", name: "Edit", subject: "Sources/x.swift", body: body, additions: 20, deletions: 2)],
                                  working: false)
        guard case let .edit(card) = rows[0] else { return XCTFail("\(rows)") }
        XCTAssertEqual(card.verb, "Edit")
        XCTAssertEqual(card.path, "Sources/x.swift")
        XCTAssertEqual(card.additions, 20)
        XCTAssertEqual(card.deletions, 2)
        XCTAssertEqual(card.lines.count, 22, "hunk headers are not shown")
        XCTAssertEqual(card.preview.count, ChatRows.editPreviewLines)
        XCTAssertEqual(card.hiddenLines, 10)
        XCTAssertEqual(card.lines[0], ChatDiffLine(kind: .removed, text: "old one"))
        XCTAssertEqual(card.lines[2], ChatDiffLine(kind: .added, text: "new 1"))
    }

    func testWriteAndMultiEditCards() {
        let write = tool("w", lead: "Wrote", name: "Write", subject: "a.txt", body: "@@ -0,0 +1,1 @@\n+hello\n", additions: 1)
        let multi = tool("m", lead: "Edited", name: "MultiEdit", subject: "b.txt",
                         body: "@@ -1,1 +1,1 @@\n-a\n+b\n\n@@ -1,1 +1,1 @@\n-c\n+d\n", additions: 2, deletions: 2)
        let rows = ChatRows.build([write, multi], working: false)
        guard case let .edit(w) = rows[0], case let .edit(m) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertEqual(w.verb, "Write")
        XCTAssertEqual(w.lines, [ChatDiffLine(kind: .added, text: "hello")])
        XCTAssertEqual(w.hiddenLines, 0)
        XCTAssertEqual(m.lines.map(\.kind), [.removed, .added, .removed, .added])
    }

    func testFailedEditIsAToolRowWithItsError() {
        let rows = ChatRows.build([tool("e", lead: "Edited", name: "Edit", subject: "a", status: "error",
                                        body: "The string to replace was not found")], working: false)
        guard case let .tool(t) = rows[0] else { return XCTFail("\(rows)") }
        XCTAssertEqual(t.status, .error)
        XCTAssertEqual(t.body, "The string to replace was not found")
    }

    func testCommandRows() {
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let rows = ChatRows.build([
            tool("ok", lead: "Ran", name: "Bash", subject: "swift build", body: "\nBuild complete! (1.2s)\nmore", ts: 1_000),
            tool("bad", lead: "Ran", name: "Bash", subject: "swift test", status: "error", body: long, ts: 2_200),
            tool("run", lead: "Ran", name: "Shell", subject: "sleep 9", status: "running", ts: 3_000),
        ], working: true)
        guard case let .commands(_, folded, _) = rows[0], let ok = folded.first, case let .command(bad) = rows[1],
              case let .command(run) = rows[2] else {
            return XCTFail("\(rows)")
        }
        XCTAssertEqual(ok.command, "swift build")
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(ok.summary, "Build complete! (1.2s)")
        XCTAssertEqual(ok.durationMs, 1_200)
        XCTAssertEqual(bad.status, .error)
        XCTAssertEqual(bad.errorLines.count, ChatRows.errorPreviewLines)
        XCTAssertEqual(bad.errorLines.first, "line 1")
        XCTAssertEqual(bad.hiddenErrorLines, 30 - ChatRows.errorPreviewLines)
        XCTAssertEqual(run.status, .running)
        XCTAssertNil(run.durationMs)
    }

    func testConsecutiveFinishedCommandsFoldIntoOneRow() throws {
        let rows = ChatRows.build([
            tool("c1", lead: "Ran", name: "Bash", subject: "git status", body: "clean", ts: 1_000),
            text("t1", "thinking", "", ts: 1_100),
            tool("c2", lead: "Ran", name: "Bash", subject: "git log", body: "abc", ts: 1_200),
            tool("r1", lead: "Read", name: "Read", subject: "a.swift", ts: 1_300),
            tool("c3", lead: "Ran", name: "Bash", subject: "swift build", ts: 1_400),
            text("t2", "thinking", " ", ts: 1_500),
            text("t3", "thinking", "Now the tests.", ts: 1_600),
            tool("c4", lead: "Ran", name: "Bash", subject: "swift test", status: "running", ts: 1_700),
        ], working: true)
        XCTAssertEqual(rows.map(\.kindName), ["commands", "tools", "commands", "thinking", "thinking", "command"])
        XCTAssertEqual(rows.map(\.id), ["group:c1", "group:r1", "group:c3", "t2", "t3", "c4"])
        guard case let .commands(_, commands, duration) = rows[0] else { return XCTFail("\(rows[0])") }
        XCTAssertEqual(commands.map(\.command), ["git status", "git log"], "empty thinking between them is dropped")
        XCTAssertEqual(commands.map(\.durationMs), [100, 100])
        XCTAssertEqual(duration, 300)
        XCTAssertTrue(rows[0].holds("c2"))
        XCTAssertTrue(rows[0].holds("group:c1"))
        XCTAssertFalse(rows[0].holds("c3"))
    }

    func testShellEditsShowAsEditCards() throws {
        var write = tool("w", lead: "Ran", name: "Bash", subject: "cat > a.txt <<'EOF'", ts: 1_000)
        write.shellEdits = ShellEdits.parse("cat > a.txt <<'EOF'\none\ntwo\nEOF")
        var noisy = tool("n", lead: "Ran", name: "Bash", subject: "cat > b.txt <<'EOF'", body: "Build complete!", ts: 2_000)
        noisy.shellEdits = ShellEdits.parse("cat > b.txt <<'EOF'\nthree\nEOF\nswift build")
        var failed = tool("f", lead: "Ran", name: "Bash", subject: "cat > /nope/c.txt <<'EOF'", status: "error", body: "No such file", ts: 3_000)
        failed.shellEdits = ShellEdits.parse("cat > /nope/c.txt <<'EOF'\nfour\nEOF")
        let rows = ChatRows.build([write, noisy, failed], working: false)
        XCTAssertEqual(rows.map(\.kindName), ["edit", "commands", "edit", "command"])
        XCTAssertEqual(rows.map(\.id), ["w#edit0", "group:n", "n#edit0", "f"])
        guard case let .edit(edit) = rows[0] else { return XCTFail("\(rows[0])") }
        XCTAssertEqual([edit.verb, edit.path], ["Write", "a.txt"])
        XCTAssertEqual(edit.additions, 2)
        XCTAssertEqual(edit.lines.map(\.text), ["one", "two"])
    }

    func testOtherToolsStandAlone() {
        let rows = ChatRows.build([
            tool("ag", lead: "Agent", name: "Task", subject: "Explore the repo"),
            tool("w", lead: "Web", name: "WebFetch", subject: "https://example.com"),
            tool("mcp", lead: "MCP", name: "mcp__linear__create_issue", subject: "Create issue"),
            tool("res", lead: "Result", name: "", status: "ok", body: "orphan"),
        ], working: false)
        XCTAssertEqual(rows.map(\.id), ["ag", "w", "mcp", "res"])
        guard case let .tool(mcp) = rows[2] else { return XCTFail() }
        XCTAssertEqual(mcp.lead, "MCP")
        XCTAssertEqual(mcp.subject, "Create issue")
    }

    func testInterruptedAndQueued() {
        let rows = ChatRows.build([
            user("u", "do it"),
            user("i1", "[Request interrupted by user]"),
            user("i2", "[Request interrupted by user for tool use]"),
            MobileTimelineEntry(id: "i3", kind: "interrupted", ts: 0),
            user("q", "and then push", state: "queued"),
        ], working: true)
        XCTAssertEqual(rows, [.user(id: "u", text: "do it", queued: false), .interrupted(id: "i1"), .interrupted(id: "i2"),
                              .interrupted(id: "i3"), .user(id: "q", text: "and then push", queued: true)])
    }

    func testUnknownKindsAndEmptyAreSkipped() {
        XCTAssertEqual(ChatRows.build([MobileTimelineEntry(id: "x", kind: "system", text: "?", ts: 0)], working: false), [])
        XCTAssertEqual(ChatRows.build([], working: true), [])
    }

    func testRowsFromAllThreeAgents() {
        let grok = ChatRows.build(GrokTimeline.entries(chatHistory: GrokTimelineTests.session), working: false)
        XCTAssertEqual(grok.map(\.kindName), ["user", "thinking", "assistant", "tools", "edit", "command", "assistant"])
        guard case let .command(cmd) = grok[5] else { return XCTFail() }
        XCTAssertEqual(cmd.errorLines, ["node: command not found"])

        let ts = "2026-11-08T12:00:00.000Z"
        let claude = [
            jsonLine(["type": "user", "uuid": "u", "timestamp": ts, "message": ["content": "go"]]),
            jsonLine(["type": "assistant", "uuid": "a", "timestamp": ts, "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/r/a"]],
                ["type": "tool_use", "id": "t2", "name": "Grep", "input": ["pattern": "x"]],
            ]]]),
            jsonLine(["type": "user", "uuid": "r", "timestamp": ts, "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "a"],
                ["type": "tool_result", "tool_use_id": "t2", "content": "b"],
            ]]]),
            jsonLine(["type": "user", "uuid": "i", "timestamp": ts, "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]]),
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(ChatRows.build(ClaudeTimeline.entries(transcript: claude), working: false).map(\.kindName), ["user", "tools", "interrupted"])

        let codex = [
            ["timestamp": ts, "type": "event_msg", "payload": ["type": "user_message", "message": "test"]],
            ["timestamp": ts, "type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "c",
                                                                  "arguments": jsonLine(["cmd": "make"])]],
            ["timestamp": ts, "type": "response_item", "payload": ["type": "function_call_output", "call_id": "c",
                                                                  "output": jsonLine(["output": "boom", "exit_code": 2])]],
        ].map(jsonLine).joined(separator: "\n") + "\n"
        XCTAssertEqual(ChatRows.build(CodexTimeline.entries(rollout: codex), working: false).map(\.kindName), ["user", "command"])
    }

    func testScreenExcerptKeepsTheLastNonEmptyLines() {
        let screen = ["", "  ❯ 1. Opus", "    2. Sonnet   ", "", "  Enter to confirm", "", ""] + Array(repeating: "", count: 3)
        XCTAssertEqual(ChatRows.screenExcerpt(screen), ["  ❯ 1. Opus", "    2. Sonnet", "  Enter to confirm"])
        let many = (1...20).map { "row \($0)" }
        XCTAssertEqual(ChatRows.screenExcerpt(many), (13...20).map { "row \($0)" })
    }
}
