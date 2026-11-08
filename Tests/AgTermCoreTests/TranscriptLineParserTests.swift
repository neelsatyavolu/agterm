import XCTest
@testable import AgTermCore

/// A transcript read a chunk at a time, as `TranscriptDiff` polls a growing file, must
/// total the same as one parse of the whole file.
final class TranscriptLineParserTests: XCTestCase {
    static let claude = [
        #"{"type":"user","timestamp":"2026-07-29T14:04:00Z","message":{"content":[{"type":"tool_result","content":"early"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-29T14:05:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":2},"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"old_string":"a","new_string":"a\nb"}}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-29T14:05:01Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":40},"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"old_string":"a","new_string":"a\nb"}}]}}"#,
        #"{"type":"user","timestamp":"2026-07-29T14:05:30Z","cwd":"/w/repo","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-29T14:06:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":5,"output_tokens":7},"content":[{"type":"tool_use","id":"t2","name":"Write","input":{"content":"x\ny\nz"}}]}}"#,
        #"{"type":"user","timestamp":"2026-07-29T14:06:10Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
    ].joined(separator: "\r\n") + "\n"

    /// Reads `text` the way a poller would: from the last offset, in pieces of `step` bytes.
    func readInChunks<P: TranscriptLineParser>(_ text: String, step: Int, into parser: inout P) {
        let bytes = Data(text.utf8)
        var offset = 0, size = 0
        while offset < bytes.count {
            size = min(bytes.count, size + step)
            offset += parser.feed(chunk: bytes[offset..<size])
        }
    }

    func testClaudeChunkedMatchesWholeParse() {
        let whole = ClaudeTranscript.parse(lines: Self.claude, sessionID: "s", fallbackDir: "/p")
        XCTAssertEqual(whole.count, 2)
        for step in [1, 7, 64, 333, Self.claude.utf8.count] {
            var parser = ClaudeTranscript.Parser(sessionID: "s", fallbackDir: "/p")
            readInChunks(Self.claude, step: step, into: &parser)
            XCTAssertEqual(parser.events, whole, "step \(step)")
        }
    }

    func testEventsCanBeReadBetweenChunksWithoutChangingTheResult() {
        var parser = ClaudeTranscript.Parser(sessionID: "s", fallbackDir: "")
        var offset = 0
        let bytes = Data(Self.claude.utf8)
        for end in stride(from: 50, through: bytes.count, by: 50) + [bytes.count] {
            offset += parser.feed(chunk: bytes[offset..<end])
            _ = parser.events
        }
        XCTAssertEqual(parser.events, ClaudeTranscript.parse(lines: Self.claude, sessionID: "s", fallbackDir: ""))
    }

    func testAPartialLineWaitsForItsNewline() {
        var parser = ClaudeTranscript.Parser(sessionID: "s", fallbackDir: "")
        let line = Self.claude.components(separatedBy: "\r\n")[1]
        XCTAssertEqual(parser.feed(chunk: Data(line.utf8)), 0)
        XCTAssertTrue(parser.events.isEmpty)
        XCTAssertEqual(parser.feed(chunk: Data((line + "\n").utf8)), line.utf8.count + 1)
        XCTAssertEqual(parser.events.count, 1)
    }

    func testCodexChunkedMatchesWholeParse() {
        let rollout = [
            jsonLine(["timestamp": "2026-07-29T14:00:00Z", "type": "session_meta", "payload": ["id": "s", "originator": "agterm", "cwd": "/w"]]),
            jsonLine(["timestamp": "2026-07-29T14:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.3-codex"]]),
            jsonLine(["timestamp": "2026-07-29T14:00:02Z", "type": "response_item", "payload": ["type": "function_call", "name": "shell"]]),
            jsonLine(["timestamp": "2026-07-29T14:00:03Z", "type": "event_msg", "payload": ["type": "token_count", "info": [
                "last_token_usage": ["input_tokens": 100, "output_tokens": 20, "reasoning_output_tokens": 5],
                "total_token_usage": ["input_tokens": 100, "output_tokens": 20]]]]),
            jsonLine(["timestamp": "2026-07-29T14:00:04Z", "type": "event_msg", "payload": ["type": "token_count", "info": [
                "last_token_usage": ["input_tokens": 50, "output_tokens": 10],
                "total_token_usage": ["input_tokens": 150, "output_tokens": 30]]]]),
        ].joined(separator: "\n") + "\n"
        let whole = CodexTranscript.parse(lines: rollout, sessionID: "s")
        XCTAssertFalse(whole.isEmpty)
        for step in [1, 13, 200, rollout.utf8.count] {
            var parser = CodexTranscript.Parser(sessionID: "s")
            readInChunks(rollout, step: step, into: &parser)
            XCTAssertEqual(parser.events, whole, "step \(step)")
        }
    }
}
