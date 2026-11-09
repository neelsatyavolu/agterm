import XCTest
@testable import AgTermCore

/// The context window figure the Chat view's title strip shows.
final class ContextUseTests: XCTestCase {
    func feed(_ agent: TimelineFeed.Agent, _ lines: [String]) -> TimelineFeed {
        ChatPerfScenarioTests.feedInPieces(agent, Data((lines.joined(separator: "\n") + "\n").utf8), size: 4096)
    }

    func testText() {
        XCTAssertEqual(ContextUse(used: 412_300, window: 1_000_000).text, "412k / 1M")
        XCTAssertEqual(ContextUse(used: 940, window: 258_400).text, "940 / 258k")
        XCTAssertEqual(ContextUse(used: 1_240_000, window: 2_000_000).text, "1.2M / 2M")
    }

    func testWindowByModel() {
        XCTAssertEqual(ContextWindow.size(model: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(ContextWindow.size(model: "claude-fable-5-2"), 1_000_000)
        XCTAssertEqual(ContextWindow.size(model: "claude-haiku-4-5-20251001"), 200_000)
        XCTAssertEqual(ContextWindow.size(model: "claude-opus-4-5"), 200_000)
        XCTAssertEqual(ContextWindow.size(model: "claude-opus-4-5[1m]"), 1_000_000)
        XCTAssertEqual(ContextWindow.size(model: "gpt-5.6-sol"), 372_000)
        XCTAssertEqual(ContextWindow.size(model: "grok-4.7-build-fast"), 500_000)
        XCTAssertEqual(ContextWindow.size(model: "something-new"), 200_000)
        XCTAssertEqual(ContextWindow.size(model: nil), 200_000)
    }

    func testClaudeCountsTheLatestMainReplysInputAndCache() {
        func reply(_ uuid: String, input: Int, write: Int, read: Int, sidechain: Bool = false) -> String {
            #"{"type":"assistant","uuid":"\#(uuid)","isSidechain":\#(sidechain),"timestamp":"2026-11-08T12:00:00Z","message":{"model":"claude-opus-5-5","#
                + #""content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write),"#
                + #""cache_read_input_tokens":\#(read),"output_tokens":500}}}"#
        }
        let feed = feed(.claude, [reply("a1", input: 100, write: 2_000, read: 30_000), reply("a2", input: 10, write: 500, read: 40_000),
                                  reply("s1", input: 5, write: 5, read: 5, sidechain: true), reply("z", input: 0, write: 0, read: 0)])
        XCTAssertEqual(feed.contextUsed, 40_510)
        XCTAssertNil(feed.contextWindow)
    }

    func testCodexReportsItsOwnWindow() {
        let feed = feed(.codex, [
            #"{"timestamp":"2026-11-09T01:15:56Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"timestamp":"2026-11-09T01:16:08Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":108966},"#
                + #""last_token_usage":{"input_tokens":39087,"cached_input_tokens":34944,"output_tokens":196},"model_context_window":828400}}}"#,
        ])
        XCTAssertEqual(feed.contextUsed, 39_087)
        XCTAssertEqual(feed.contextWindow, 828_400)
    }

    func testGrokSignals() {
        XCTAssertEqual(ContextUse(grokSignals: #"{"contextTokensUsed":1523,"contextWindowTokens":256000}"#, model: nil), ContextUse(used: 1_523, window: 256_000))
        XCTAssertEqual(ContextUse(grokSignals: #"{"contextTokensUsed":9000}"#, model: "grok-4.7")?.window, 500_000)
        XCTAssertNil(ContextUse(grokSignals: #"{"contextTokensUsed":0}"#, model: nil))
        XCTAssertNil(ContextUse(grokSignals: "not json", model: nil))
    }
}
