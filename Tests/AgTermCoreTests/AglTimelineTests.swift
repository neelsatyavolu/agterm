import XCTest
@testable import AgTermCore

/// agl session files (`~/.agl/sessions/<cwd>/<stamp>-<id>.jsonl`) → timeline. Fixture lines are
/// trimmed copies of a real agl 0.1 session against LM Studio.
final class AglTimelineTests: XCTestCase {
    static let session: String = [
        jsonLine(["type": "session", "id": "6cafcca4", "cwd": "/w/proj", "model": "qwen3.8-27b-splash",
                  "base_url": "http://127.0.0.1:1235/v1", "started": "2026-11-08T23:53:30Z", "ts": 1_794_182_010_000]),
        jsonLine(["type": "user", "text": "Fix the bug in add.py so that python3 add.py prints 5.", "ts": 1_794_182_010_826]),
        jsonLine(["type": "assistant", "text": "", "reasoning": "Let's take a look at add.py.\n", "ts": 1_794_182_036_427]),
        jsonLine(["type": "tool_call", "id": "c1", "name": "read", "arguments": ["path": "add.py"], "ts": 1_794_182_036_427]),
        jsonLine(["type": "tool_result", "id": "c1", "ok": true, "output": "     1\tdef add(a, b):\n     2\t    return a - b",
                  "ts": 1_794_182_036_500]),
        jsonLine(["type": "assistant", "text": "", "reasoning": "", "ts": 1_794_182_040_226]),
        jsonLine(["type": "tool_call", "id": "c2", "name": "edit",
                  "arguments": ["path": "add.py", "old": "    return a - b", "new": "    return a + b"], "ts": 1_794_182_040_226]),
        jsonLine(["type": "tool_result", "id": "c2", "ok": true, "output": "edited add.py at line 2", "ts": 1_794_182_040_300]),
        jsonLine(["type": "tool_call", "id": "c3", "name": "bash", "arguments": ["command": "python3 add.py"], "ts": 1_794_182_042_020]),
        jsonLine(["type": "tool_result", "id": "c3", "ok": false, "output": "Traceback\n[exit code 1]", "ts": 1_794_182_042_069]),
        jsonLine(["type": "assistant", "text": "Fixed `add.py`.", "reasoning": "Done.", "ts": 1_794_182_043_643]),
    ].joined(separator: "\n") + "\n"

    func testSessionBecomesRows() {
        let rows = RemoteTimeline.agl(session: Self.session)
        XCTAssertEqual(rows.map(\.kind), ["user", "thinking", "tool", "tool", "tool", "thinking", "assistant"])
        XCTAssertEqual(rows[0].text, "Fix the bug in add.py so that python3 add.py prints 5.")
        XCTAssertEqual(rows[0].ts, 1_794_182_010_826)
        XCTAssertEqual(rows[1].text, "Let's take a look at add.py.")
        XCTAssertNoThrow(try RemoteTimeline.assertRenderable(rows))
    }

    func testToolsReadLikeOtherAgents() {
        let rows = RemoteTimeline.agl(session: Self.session).filter { $0.kind == "tool" }
        XCTAssertEqual(rows.map(\.lead), ["Read", "Edited", "Ran"])
        XCTAssertEqual(rows.map(\.subject), ["add.py", "add.py", "python3 add.py"])
        XCTAssertEqual(rows.map(\.status), ["ok", "ok", "error"])
        XCTAssertEqual(rows[1].additions, 1)
        XCTAssertEqual(rows[1].deletions, 1)
        XCTAssertEqual(rows[2].requestId, "c3")
        XCTAssertEqual(rows[2].endTs, 1_794_182_042_069)
    }

    func testRunningToolAndModel() {
        let partial = Self.session.split(separator: "\n").prefix(4).joined(separator: "\n") + "\n"
        var t = AglTimeline()
        partial.split(separator: "\n").forEach { t.feed(String($0)) }
        XCTAssertEqual(t.entries.last?.status, "running")
        XCTAssertEqual(t.model, "qwen3.8-27b-splash")
        t.feed(jsonLine(["type": "model", "name": "qwen3-4b", "ts": 1]))
        XCTAssertEqual(t.model, "qwen3-4b")
        XCTAssertEqual(RemoteTimeline.modelLabel(agl: Self.session), "qwen3.8-27b-splash")
    }

    func testErrorsShowAndJunkIsSkipped() {
        let text = [jsonLine(["type": "user", "text": "hi", "ts": 5]), "not json", "",
                    jsonLine(["type": "error", "message": "cannot reach http://127.0.0.1:1234/v1", "ts": 6])].joined(separator: "\n") + "\n"
        let rows = RemoteTimeline.agl(session: text)
        XCTAssertEqual(rows.map(\.kind), ["user", "assistant"])
        XCTAssertEqual(rows[1].text, "agl stopped: cannot reach http://127.0.0.1:1234/v1")
    }

    func testFeedReadsAppendedLinesWithStableIDs() {
        var feed = TimelineFeed(agent: .agl)
        let lines = Self.session.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let half = lines.prefix(5).joined(separator: "\n") + "\n"
        feed.feed(chunk: Data(half.utf8))
        let ids = feed.entries.map(\.id)
        feed.feed(chunk: Data((lines.dropFirst(5).joined(separator: "\n")).utf8))
        XCTAssertEqual(Array(feed.entries.map(\.id).prefix(ids.count)), ids)
        XCTAssertEqual(feed.entries.count, 7)
        XCTAssertEqual(feed.model, "qwen3.8-27b-splash")
    }

    func testAglIsAKnownAgentThatResumes() {
        XCTAssertEqual(AgentKind.named("agl")?.title, "agl")
        XCTAssertNil(AgentKind.named("agl")?.bypassFlags, "agl has no permission prompts")
        XCTAssertEqual(AgentResume.continueCommandLine(agent: "agl", argv: ["agl"]), "command agl --resume")
        XCTAssertNil(AgentResume.continueCommandLine(agent: "agl", argv: ["agl", "-p", "x"]))
    }

    func testRestoreResumesTheTabsOwnSessionWithItsOptions() {
        let file = URL(fileURLWithPath: "/h/.agl/sessions/-w/20261108T235330Z-6cafcca4.jsonl")
        XCTAssertEqual(AgentResume.aglCommandLine(argv: ["agl", "--model", "qwen3-4b", "--plain", "--resume", "old"], session: file),
                       "command agl --resume 20261108T235330Z-6cafcca4 --model qwen3-4b --plain")
        XCTAssertEqual(AgentResume.aglCommandLine(argv: ["/opt/bin/agl", "--resume"], session: file),
                       "command agl --resume 20261108T235330Z-6cafcca4")
        XCTAssertNil(AgentResume.aglCommandLine(argv: ["agl", "-p", "fix it"], session: file), "one-shot runs end")
        XCTAssertNil(AgentResume.aglCommandLine(argv: ["agl", "models"], session: file))
    }

    func testRunPointerNamesTheSession() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("run"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? #"{"session":"/h/.agl/sessions/-w/a.jsonl"}"#.write(to: dir.appendingPathComponent("run/4242.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AglSessions.running(pid: 4242, home: dir)?.path, "/h/.agl/sessions/-w/a.jsonl")
        XCTAssertNil(AglSessions.running(pid: 1, home: dir))
    }
}
