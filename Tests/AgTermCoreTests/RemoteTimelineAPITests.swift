import XCTest
@testable import AgTermCore

/// The public `RemoteTimeline` surface: wire shape, caps, model labels and
/// whole-file behaviour agmux gets from its file readers.
final class RemoteTimelineAPITests: XCTestCase {
    func testEntryEncodesCamelCaseAndOmitsNilFields() throws {
        let entry = MobileTimelineEntry(id: "t1", kind: "tool", lead: "Edited", status: "ok", additions: 2,
                                        body: "", requestId: "call-1", toolName: "Edit", ts: 1_700_000_000_000)
        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "lead", "status", "additions", "body", "requestId", "toolName", "ts"])
        XCTAssertEqual(object["requestId"] as? String, "call-1")
        XCTAssertEqual(object["ts"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(try JSONDecoder().decode(MobileTimelineEntry.self, from: data), entry)
        // agmux rows decode too (serde `default` on every optional).
        let wire = Data(#"{"id":"u","kind":"user","text":"hi","state":"queued","ts":5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MobileTimelineEntry.self, from: wire),
                       MobileTimelineEntry(id: "u", kind: "user", text: "hi", state: "queued", ts: 5))
    }

    func testClaudeTranscriptEndToEnd() throws {
        let lines = [
            jsonLine(["type": "user", "uuid": "u1", "timestamp": "2026-09-24T18:00:00.000Z", "message": ["content": "fix it"]]),
            jsonLine(["type": "assistant", "uuid": "a1", "timestamp": "2026-09-24T18:00:01.000Z",
                      "message": ["model": "claude-opus-4-5-20251101", "content": [
                        ["type": "thinking", "thinking": "look first"],
                        ["type": "text", "text": "On it."],
                        ["type": "tool_use", "id": "tu1", "name": "Bash", "input": ["command": "ls"]]]]]),
            jsonLine(["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-09-24T18:00:02.000Z", "content": "then push"]),
        ]
        // The trailing record has no newline yet: agmux leaves it for the next read.
        let partial = jsonLine(["type": "user", "uuid": "u2", "timestamp": "2026-09-24T18:00:03.000Z", "message": ["content": "late"]])
        let entries = RemoteTimeline.claude(transcript: lines.joined(separator: "\n") + "\n" + partial)
        XCTAssertEqual(entries.map(\.kind), ["user", "thinking", "assistant", "tool", "user"])
        XCTAssertEqual(entries.map(\.id), ["u1", "a1-0", "a1-1", "a1-2", "queued-0"])
        XCTAssertEqual(entries[0].ts, 1_790_272_800_000)
        XCTAssertEqual(entries[3].status, "running")
        XCTAssertEqual(entries[3].requestId, "tu1")
        XCTAssertEqual(entries[4].text, "then push")
        XCTAssertEqual(entries[4].state, "queued")
        XCTAssertNoThrow(try RemoteTimeline.assertRenderable(entries))
    }

    func testDeliveredSteeringMovesToItsSendTime() {
        let lines = [
            jsonLine(["type": "user", "uuid": "u1", "timestamp": "2026-09-24T18:00:00.000Z", "message": ["content": "first"]]),
            jsonLine(["type": "assistant", "uuid": "a1", "timestamp": "2026-09-24T18:00:05.000Z", "message": ["content": [["type": "text", "text": "done"]]]]),
            jsonLine(["type": "attachment", "uuid": "q1", "timestamp": "2026-09-24T18:00:02.000Z",
                      "attachment": ["type": "queued_command", "prompt": "steer"]]),
            jsonLine(["type": "user", "uuid": "u2", "timestamp": "2026-09-24T18:00:06.000Z", "message": ["content": "steer"]]),
        ]
        let entries = RemoteTimeline.claude(transcript: lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(entries.map(\.id), ["u1", "q1", "a1"])
    }

    func testTimelinesKeepTheNewest250Rows() {
        let lines = (0..<300).map { i in
            jsonLine(["type": "user", "uuid": "u\(i)", "timestamp": "2026-09-24T18:00:00.000Z", "message": ["content": "m\(i)"]])
        }
        let entries = RemoteTimeline.claude(transcript: lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(entries.count, RemoteTimeline.maxEntries)
        XCTAssertEqual(entries.first?.text, "m50")
        XCTAssertEqual(entries.last?.text, "m299")
    }

    func testCodexRolloutEndToEnd() throws {
        let records: [[String: Any]] = [
            ["type": "turn_context", "payload": ["model": "gpt-5.3-codex"]],
            ["type": "event_msg", "timestamp": "2026-08-05T12:00:00Z", "payload": ["type": "user_message", "message": "run tests"]],
            ["type": "response_item", "timestamp": "2026-08-05T12:00:00Z",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "run tests"]]]],
            ["type": "response_item", "payload": ["type": "reasoning", "summary": [["type": "summary_text", "text": "plan"]]]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "c1",
                                                  "arguments": #"{"cmd":"swift test"}"#]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1",
                                                  "output": #"{"output":"ok\n","metadata":{"exit_code":0}}"#]],
            ["type": "event_msg", "payload": ["type": "patch_apply_end", "call_id": "p1", "success": true,
                                              "changes": ["/repo/a.swift": ["type": "update", "unified_diff": "@@\n-a\n+b\n+c"]]]],
            ["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "All green."]]]],
        ]
        let text = records.map(jsonLine).joined(separator: "\n")
        let entries = RemoteTimeline.codex(rollout: text)
        XCTAssertEqual(entries.map(\.kind), ["user", "thinking", "tool", "tool", "assistant"])
        XCTAssertEqual(entries[2].lead, "Ran")
        XCTAssertEqual(entries[2].subject, "swift test")
        XCTAssertEqual(entries[2].body, "ok")
        XCTAssertEqual(entries[2].status, "ok")
        XCTAssertEqual(entries[3].lead, "Edited")
        XCTAssertEqual(entries[3].subject, "/repo/a.swift")
        XCTAssertEqual(entries[3].additions, 2)
        XCTAssertEqual(entries[3].deletions, 1)
        XCTAssertNoThrow(try RemoteTimeline.assertRenderable(entries))
        XCTAssertEqual(RemoteTimeline.modelLabel(codex: text), "gpt-5.6-sol")
    }

    func testClaudeModelLabelPrefersTheLatestRealModel() {
        func assistant(_ model: String) -> String {
            jsonLine(["type": "assistant", "message": ["model": model, "content": [["type": "text", "text": "x"]]]])
        }
        let text = [assistant("claude-sonnet-4-6"), assistant("claude-opus-4-5-20251101"), assistant("<synthetic>")].joined(separator: "\n")
        XCTAssertEqual(RemoteTimeline.modelLabel(claude: text), "claude-opus-4-5-20251101")
        XCTAssertNil(RemoteTimeline.modelLabel(claude: jsonLine(["type": "user", "message": ["content": "hi"]])))
        // A long tool result filling the tail falls back to the head's first model.
        let filler = jsonLine(["type": "user", "message": ["content": String(repeating: "z", count: 70_000)]])
        XCTAssertEqual(RemoteTimeline.modelLabel(claude: assistant("claude-opus-4-5") + "\n" + filler), "claude-opus-4-5")
    }

    func testAssertRenderableRejectsJunk() {
        XCTAssertThrowsError(try RemoteTimeline.assertRenderable([MobileTimelineEntry(id: "", kind: "user", text: "x", ts: 0)]))
        XCTAssertThrowsError(try RemoteTimeline.assertRenderable([MobileTimelineEntry(id: "a", kind: "approval", ts: 0)]))
        XCTAssertThrowsError(try RemoteTimeline.assertRenderable([MobileTimelineEntry(id: "a", kind: "assistant", text: "  ", ts: 0)]))
        XCTAssertThrowsError(try RemoteTimeline.assertRenderable([MobileTimelineEntry(id: "a", kind: "tool", ts: 0)]))
        XCTAssertNoThrow(try RemoteTimeline.assertRenderable([MobileTimelineEntry(id: "a", kind: "tool", toolName: "Bash", ts: 0)]))
    }

    func testTimestampsParseLikeAgmux() {
        XCTAssertEqual(parseLogTimestamp("2026-09-24T18:04:51.084Z"), 1_790_273_091_084)
        XCTAssertEqual(parseLogTimestamp("2026-09-24T20:04:51.084+02:00"), 1_790_273_091_084)
        XCTAssertEqual(parseLogTimestamp("2026-07-13 12:00:00.000"), 1_783_944_000_000)
        XCTAssertEqual(parseLogTimestamp("2026-07-13 12:00:00"), 1_783_944_000_000)
        XCTAssertEqual(parseLogTimestamp(""), 0)
        XCTAssertEqual(parseLogTimestamp("yesterday"), 0)
    }
}
