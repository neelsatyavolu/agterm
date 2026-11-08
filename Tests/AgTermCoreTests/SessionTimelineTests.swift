import XCTest
@testable import AgTermCore

/// Session Timeline turns from Claude Code, Codex and Grok transcripts.
final class SessionTimelineTests: XCTestCase {
    private func feed<P: SessionTimelineFeed>(_ parser: inout P, _ lines: [String]) {
        for line in lines { parser.feed(line) }
    }

    // MARK: Claude

    private func claudeUser(_ text: String, prompt: String = "p1", uuid: String = "u1", meta: Bool = false) -> String {
        #"{"type":"user","promptId":"\#(prompt)","uuid":"\#(uuid)","isMeta":\#(meta),"timestamp":"2026-11-08T10:00:00.000Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    func testClaudePromptsAndStatuses() {
        var parser = SessionTimelineClaude()
        feed(&parser, [
            claudeUser("Fix the login bug"),
            #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"#,
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#,
            claudeUser("Now add a test", prompt: "p2", uuid: "u2"),
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            claudeUser("Try again", prompt: "p3", uuid: "u4"),
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error"}]}}"#,
            claudeUser("Last one", prompt: "p4", uuid: "u5"),
        ])
        XCTAssertEqual(parser.turns.map(\.prompt), ["Fix the login bug", "Now add a test", "Try again", "Last one"])
        XCTAssertEqual(parser.turns.map(\.status), [.done, .cancelled, .failed, .running])
        XCTAssertEqual(parser.turns.map(\.id), ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(parser.turns[0].startedAt, 1_794_132_000_000)
    }

    func testClaudeSkipsPlumbing() {
        var parser = SessionTimelineClaude()
        feed(&parser, [
            claudeUser("<local-command-caveat>Caveat</local-command-caveat>", meta: true),
            claudeUser("<command-name>/clear</command-name>", prompt: "p2"),
            claudeUser("/review", prompt: "p3", meta: true),
            #"{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued"}}"#,
            #"{"type":"user","isSidechain":true,"promptId":"s","message":{"content":"subagent task"}}"#,
            claudeUser("Real prompt<system-reminder>x</system-reminder>", prompt: "p4"),
            #"{"type":"system","subtype":"turn_duration","durationMs":5}"#,
        ])
        XCTAssertEqual(parser.turns.map(\.prompt), ["/review", "Real prompt"])
        XCTAssertEqual(parser.turns.map(\.status), [.done, .done])
    }

    func testFeedChunkKeepsPartialLine() {
        var parser = SessionTimelineClaude()
        let line = claudeUser("Hello there")
        let data = Data((line + "\n" + line.prefix(10)).utf8)
        XCTAssertEqual(parser.feed(chunk: data), line.utf8.count + 1)
        XCTAssertEqual(parser.turns.count, 1)
    }

    // MARK: Codex

    func testCodexTurns() {
        var parser = SessionTimelineCodex()
        feed(&parser, [
            #"{"timestamp":"2026-11-08T10:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            ##"{"timestamp":"2026-11-08T10:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n..."}]}}"##,
            #"{"timestamp":"2026-11-08T10:00:00.200Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Rename the module"}]}}"#,
            #"{"timestamp":"2026-11-08T10:00:00.200Z","type":"event_msg","payload":{"type":"user_message","message":"Rename the module"}}"#,
            #"{"timestamp":"2026-11-08T10:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#,
            #"{"timestamp":"2026-11-08T10:01:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_id":"t2"}}}"#,
            #"{"timestamp":"2026-11-08T10:01:00.100Z","type":"event_msg","payload":{"type":"user_message","message":"Run the tests"}}"#,
            #"{"timestamp":"2026-11-08T10:01:03.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2","reason":"interrupted"}}"#,
            #"{"timestamp":"2026-11-08T10:02:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t3"}}"#,
            #"{"timestamp":"2026-11-08T10:02:00.100Z","type":"event_msg","payload":{"type":"user_message","message":"Again"}}"#,
        ])
        XCTAssertEqual(parser.turns.map(\.prompt), ["Rename the module", "Run the tests", "Again"])
        XCTAssertEqual(parser.turns.map(\.status), [.done, .cancelled, .running])
        XCTAssertEqual(parser.turns.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(parser.turns[0].startedAt, 1_794_132_000_000)
    }

    func testCodexWithoutTurnEvents() {
        var parser = SessionTimelineCodex()
        feed(&parser, [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"First"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"First"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Second"}}"#,
        ])
        XCTAssertEqual(parser.turns.map(\.prompt), ["First", "Second"])
        XCTAssertEqual(parser.turns.map(\.status), [.done, .running])
    }

    // MARK: Grok

    func testGrokMergesPromptsAndEvents() {
        var prompts = SessionTimelineGrok.Prompts()
        feed(&prompts, [
            #"{"type":"system","content":"You are Grok"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_info>x</user_info>"}]}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_query>\nShip it\n</user_query>"}],"prompt_index":0}"#,
            #"{"type":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}],"synthetic_reason":"system_reminder"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_query>Stop</user_query>"}],"prompt_index":1}"#,
            #"{"type":"user","content":"<user_query>Next</user_query>","prompt_index":2}"#,
        ])
        var events = SessionTimelineGrok.Events()
        feed(&events, [
            #"{"ts":"2026-11-08T10:00:00.000Z","type":"turn_started","turn_number":0}"#,
            #"{"ts":"2026-11-08T10:00:01.000Z","type":"phase_changed","phase":"waiting_for_model"}"#,
            #"{"ts":"2026-11-08T10:00:09.000Z","type":"turn_ended","outcome":"completed"}"#,
            #"{"ts":"2026-11-08T10:01:00.000Z","type":"turn_started","turn_number":1}"#,
            #"{"ts":"2026-11-08T10:01:02.000Z","type":"turn_ended","outcome":"cancelled"}"#,
        ])
        let turns = SessionTimelineGrok.merge(prompts, events, sessionID: "s")
        XCTAssertEqual(turns.map(\.prompt), ["Ship it", "Stop", "Next"])
        XCTAssertEqual(turns.map(\.status), [.done, .cancelled, .running])
        XCTAssertEqual(turns.map(\.startedAt), [1_794_132_000_000, 1_794_132_060_000, nil])
    }

    // MARK: Formatting

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SessionTimelineFormat.relative(nil, now: now), "")
        XCTAssertEqual(SessionTimelineFormat.relative(1_000_000_000 - 10_000, now: now), "now")
        XCTAssertEqual(SessionTimelineFormat.relative(1_000_000_000 - 300_000, now: now), "5m")
        XCTAssertEqual(SessionTimelineFormat.relative(1_000_000_000 - 7_200_000, now: now), "2h")
        XCTAssertEqual(SessionTimelineFormat.relative(1_000_000_000 - 3 * 86_400_000, now: now), "3d")
    }

    func testCleanPrompt() {
        XCTAssertEqual(SessionTimelineFormat.cleanPrompt("  <user_query>\n hi \n</user_query> "), "hi")
        XCTAssertEqual(SessionTimelineFormat.cleanPrompt("<user_query>open"), "open")
        XCTAssertEqual(SessionTimelineFormat.cleanPrompt("plain"), "plain")
        XCTAssertEqual(SessionTimelineFormat.oneLine("a\n  b\tc"), "a b c")
    }
}
