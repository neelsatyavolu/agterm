import XCTest
@testable import AgTermCore

/// The tokens, cost, model and lines a Grok tab's card shows.
final class GrokUsageTests: XCTestCase {
    /// Trimmed from a real Grok 1.0.79 `usage.json`.
    let usage = """
    {"sessionId":"ecffea9f","session":{"inputTokens":720604,"outputTokens":29565,"cachedReadTokens":614656,
    "cacheCreationTokens":0,"reasoningTokens":15882,"totalTokens":750169,"modelCalls":9,
    "costUsdTicks":13932280000,"turnCount":1,"primaryModelId":"grok-4.7-build-fast"},"turns":[]}
    """

    func testReadsTokensCostAndModel() throws {
        let grok = try XCTUnwrap(GrokUsage(usage: usage, signals: nil))
        XCTAssertEqual(grok.tokens, 720_604 - 614_656 + 29_565)
        XCTAssertEqual(grok.costUSD, 1.393228, accuracy: 0.000001)
        XCTAssertEqual(grok.model, "grok-4.7-build-fast")
        XCTAssertEqual(grok.added, 0)
        XCTAssertEqual(grok.removed, 0)
    }

    func testReadsLinesFromSignals() throws {
        let grok = try XCTUnwrap(GrokUsage(usage: usage, signals: #"{"agentLinesAdded":552,"agentLinesRemoved":76,"humanLinesAdded":9}"#))
        XCTAssertEqual(grok.added, 552)
        XCTAssertEqual(grok.removed, 76)
    }

    func testNegativeLineCountIsNone() throws {
        let grok = try XCTUnwrap(GrokUsage(usage: usage, signals: #"{"agentLinesAdded":1834,"agentLinesRemoved":-674}"#))
        XCTAssertEqual(grok.removed, 0)
    }

    func testRejectsAFileWithoutASession() {
        XCTAssertNil(GrokUsage(usage: #"{"sessionId":"x"}"#, signals: nil))
        XCTAssertNil(GrokUsage(usage: "not json", signals: nil))
    }
}
