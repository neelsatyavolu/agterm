import XCTest
@testable import AgTermCore

/// The chat view's incremental reader: appended bytes in, the whole timeline out,
/// matching a full parse of the same complete lines.
final class TimelineFeedTests: XCTestCase {
    let ts = "2026-11-08T12:00:00.000Z"

    func claudeLine(_ type: String, uuid: String, content: Any, model: String? = nil, extra: [String: Any] = [:]) -> String {
        var message: [String: Any] = ["content": content]
        if let model { message["model"] = model }
        return jsonLine(["type": type, "uuid": uuid, "timestamp": ts, "message": message].merging(extra) { $1 })
    }

    var claudeTranscript: String {
        [
            claudeLine("user", uuid: "u1", content: "Add a test"),
            claudeLine("assistant", uuid: "a1", content: [["type": "thinking", "thinking": "Plan it."],
                                                          ["type": "text", "text": "Reading."],
                                                          ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/r/a.swift"]]],
                       model: "claude-opus-5-5"),
            claudeLine("user", uuid: "u2", content: [["type": "tool_result", "tool_use_id": "t1", "content": "line 1"]]),
            claudeLine("assistant", uuid: "a2", content: [["type": "tool_use", "id": "t2", "name": "Edit",
                                                          "input": ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b\nc"]]]),
            claudeLine("user", uuid: "u3", content: [["type": "tool_result", "tool_use_id": "t2", "content": "ok"]]),
            claudeLine("assistant", uuid: "a3", content: [["type": "text", "text": "Done — 完了 ✅"]]),
            jsonLine(["type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": "and push it"]),
        ].joined(separator: "\n") + "\n"
    }

    func codexRollout(pendingCommand: Bool = false, aborted: Bool = false) -> String {
        var records: [[String: Any]] = [
            ["timestamp": ts, "type": "turn_context", "payload": ["model": "gpt-5.5-codex"]],
            ["timestamp": ts, "type": "event_msg", "payload": ["type": "user_message", "message": "run the tests"]],
            ["timestamp": ts, "type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "c1",
                                                                  "arguments": jsonLine(["cmd": "swift test"])]],
            ["timestamp": ts, "type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1",
                                                                  "output": jsonLine(["output": "ok", "exit_code": 0])]],
            ["timestamp": ts, "type": "response_item", "payload": ["type": "message", "role": "assistant",
                                                                  "content": [["type": "output_text", "text": "All green."]]]],
        ]
        if pendingCommand {
            records.append(["timestamp": ts, "type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "c2",
                                                                                 "arguments": jsonLine(["cmd": "sleep 100"])]])
        }
        if aborted {
            records.append(["timestamp": ts, "type": "event_msg", "payload": ["type": "turn_aborted", "reason": "interrupted"]])
        }
        return records.map(jsonLine).joined(separator: "\n") + "\n"
    }

    /// Feeds `text` in pieces of `size` bytes, as polls of a growing file would.
    func feedInPieces(_ agent: TimelineFeed.Agent, _ text: String, size: Int) -> TimelineFeed {
        var feed = TimelineFeed(agent: agent)
        let data = Data(text.utf8)
        var pending = Data()
        var start = 0
        while start < data.count {
            pending += data[start..<min(start + size, data.count)]
            let used = feed.feed(chunk: pending)
            pending = pending.dropFirst(used)
            start += size
        }
        XCTAssertEqual(feed.offset, data.count)
        return feed
    }

    // MARK: Equivalence with a full parse

    func testClaudeFeedMatchesAFullParseForAnyChunking() {
        let text = claudeTranscript
        let whole = ClaudeTimeline.entries(transcript: text, chatMarkers: true)
        XCTAssertEqual(whole.last?.state, "queued")
        for size in [1, 7, 64, 300, text.utf8.count] {
            let feed = feedInPieces(.claude, text, size: size)
            XCTAssertEqual(feed.entries, whole, "chunk size \(size)")
            XCTAssertEqual(feed.model, "claude-opus-5-5")
        }
    }

    func testCodexFeedMatchesAFullParse() {
        let text = codexRollout()
        let feed = feedInPieces(.codex, text, size: 50)
        XCTAssertEqual(feed.entries, CodexTimeline.entries(rollout: text))
        XCTAssertEqual(feed.model, "gpt-5.5-codex")
    }

    func testGrokFeedMatchesAFullParse() {
        let text = GrokTimelineTests.session
        let feed = feedInPieces(.grok, text, size: 33)
        XCTAssertEqual(feed.entries, GrokTimeline.entries(chatHistory: text))
        XCTAssertEqual(feed.model, "grok-4.7-build-fast")
    }

    // MARK: Partial lines

    func testTruncatedLastLineIsLeftForTheNextChunk() {
        for agent in [TimelineFeed.Agent.claude, .codex, .grok, .agl] {
            let line: String
            switch agent {
            case .claude: line = claudeLine("assistant", uuid: "a", content: [["type": "text", "text": "partial reply"]])
            case .codex: line = jsonLine(["timestamp": ts, "type": "response_item",
                                          "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "partial reply"]]]])
            case .grok: line = GrokTimelineTests.assistant("partial reply")
            case .agl: line = jsonLine(["type": "assistant", "text": "partial reply", "reasoning": "", "ts": 1])
            }
            var feed = TimelineFeed(agent: agent)
            let data = Data((line + "\n").utf8)
            let head = data.prefix(data.count - 10)
            XCTAssertEqual(feed.feed(chunk: head), 0, "\(agent)")
            XCTAssertEqual(feed.entries, [], "\(agent)")
            XCTAssertEqual(feed.feed(chunk: data), data.count, "\(agent)")
            XCTAssertEqual(feed.entries.map(\.text), ["partial reply"], "\(agent)")
        }
    }

    func testMalformedLineIsSkippedNotFatal() {
        var feed = TimelineFeed(agent: .claude)
        let text = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"te\n" + claudeLine("user", uuid: "u", content: "after") + "\n"
        XCTAssertEqual(feed.feed(chunk: Data(text.utf8)), text.utf8.count)
        XCTAssertEqual(feed.entries.map(\.text), ["after"])
    }

    func testEmptyChunkChangesNothing() {
        var feed = TimelineFeed(agent: .grok)
        XCTAssertEqual(feed.feed(chunk: Data()), 0)
        XCTAssertEqual(feed.entries, [])
        XCTAssertNil(feed.model)
    }

    // MARK: Growth

    func testRunningToolFinishesInALaterChunk() {
        var feed = TimelineFeed(agent: .claude)
        let use = claudeLine("assistant", uuid: "a", content: [["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "make"]]]) + "\n"
        _ = feed.feed(chunk: Data(use.utf8))
        XCTAssertEqual(feed.entries.map(\.status), ["running"])
        let before = feed.entries
        let done = claudeLine("user", uuid: "u", content: [["type": "tool_result", "tool_use_id": "t", "content": "built", "is_error": false]]) + "\n"
        _ = feed.feed(chunk: Data(done.utf8))
        XCTAssertEqual(feed.entries.map(\.status), ["ok"])
        XCTAssertEqual(TimelineDiff.firstChange(from: before, to: feed.entries), 0)
    }

    func testCodexInterruptAndRunningCommandShowInChat() {
        let running = feedInPieces(.codex, codexRollout(pendingCommand: true), size: 4096)
        XCTAssertEqual(running.entries.last?.subject, "sleep 100")
        XCTAssertEqual(running.entries.last?.status, "running")
        // Esc ends the turn: the command stops spinning and the turn shows as interrupted.
        let aborted = feedInPieces(.codex, codexRollout(pendingCommand: true, aborted: true), size: 4096)
        XCTAssertEqual(aborted.entries.suffix(2).map(\.kind), ["tool", "interrupted"])
        XCTAssertEqual(aborted.entries.suffix(2).first?.status, "error")
        // The phone timeline is unchanged by chat-only markers.
        let phone = RemoteTimeline.codex(rollout: codexRollout(pendingCommand: true, aborted: true))
        XCTAssertFalse(phone.contains { $0.kind == "interrupted" })
        XCTAssertEqual(phone.last?.status, "ok")
    }

    /// A very long transcript is read from a line part-way in; offsets stay file offsets.
    func testFeedStartingPartWayIn() {
        let first = claudeLine("user", uuid: "old", content: "old") + "\n"
        let rest = claudeLine("user", uuid: "u2", content: "new") + "\n"
        var feed = TimelineFeed(agent: .claude, offset: first.utf8.count)
        XCTAssertEqual(feed.startOffset, first.utf8.count)
        XCTAssertEqual(feed.feed(chunk: Data(rest.utf8)), rest.utf8.count)
        XCTAssertEqual(feed.offset, first.utf8.count + rest.utf8.count)
        XCTAssertEqual(feed.entries.map(\.id), ["u2"])
    }

    func testResumedSessionReadsFromTheStart() {
        // Resuming an old Claude session appends to its file; a new feed reads all of it.
        let feed = feedInPieces(.claude, claudeTranscript + claudeLine("user", uuid: "u9", content: "resumed") + "\n", size: 1 << 20)
        XCTAssertEqual(feed.entries.first?.text, "Add a test")
        XCTAssertTrue(feed.entries.contains { $0.text == "resumed" })
    }

    // MARK: Diff

    func testFirstChangeByIndex() {
        func e(_ id: String, _ text: String = "x") -> MobileTimelineEntry { MobileTimelineEntry(id: id, kind: "assistant", text: text, ts: 0) }
        XCTAssertNil(TimelineDiff.firstChange(from: [e("a"), e("b")], to: [e("a"), e("b")]))
        XCTAssertEqual(TimelineDiff.firstChange(from: [e("a"), e("b")], to: [e("a"), e("b"), e("c")]), 2)
        XCTAssertEqual(TimelineDiff.firstChange(from: [e("a"), e("b")], to: [e("a"), e("b", "y")]), 1)
        XCTAssertEqual(TimelineDiff.firstChange(from: [e("a"), e("b")], to: [e("a")]), 1)
        XCTAssertEqual(TimelineDiff.firstChange(from: [e("a")], to: [e("z")]), 0)
        XCTAssertEqual(TimelineDiff.firstChange(from: [], to: [e("a")]), 0)
        XCTAssertNil(TimelineDiff.firstChange(from: [MobileTimelineEntry](), to: []))
    }

    // MARK: Size

    func testTenThousandEntriesReadQuicklyAndAppendCheaply() {
        var lines: [String] = []
        for i in 0..<5_000 {
            lines.append(claudeLine("user", uuid: "u\(i)", content: "question \(i)"))
            lines.append(claudeLine("assistant", uuid: "a\(i)", content: [["type": "text", "text": "answer \(i) " + String(repeating: "word ", count: 20)]]))
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        var feed = TimelineFeed(agent: .claude)
        let start = Date()
        XCTAssertEqual(feed.feed(chunk: data), data.count)
        let opened = Date().timeIntervalSince(start)
        XCTAssertEqual(feed.entries.count, 10_000)

        let more = Data((claudeLine("assistant", uuid: "late", content: [["type": "text", "text": "one more"]]) + "\n").utf8)
        let appendStart = Date()
        _ = feed.feed(chunk: more)
        let appended = Date().timeIntervalSince(appendStart)
        XCTAssertEqual(feed.entries.count, 10_001)
        // Debug builds are slow; these bounds catch a quadratic or full re-parse, not micro-regressions.
        XCTAssertLessThan(opened, 3.0)
        XCTAssertLessThan(appended, 0.05)
    }
}
