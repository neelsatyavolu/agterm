import XCTest
@testable import AgTermCore

final class UsageCacheTests: XCTestCase {
    private func event(_ session: String, cost: Double = 0.25, incomplete: Bool = false) -> UsageEvent {
        var e = UsageEvent(at: Date(timeIntervalSince1970: 1_800_000_000.125), provider: "ClaudeCode",
                           model: "claude-opus-5-5", projectKey: "agterm", sessionID: session)
        (e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite, e.reasoning) = (10, 20, 30, 40, 5)
        e.costUSD = cost
        e.costIncomplete = incomplete
        e.isTurn = true
        e.toolCalls = 3
        e.claudeRowKey = "msg_1:req_1"
        e.isSidechain = true
        e.isSubagentPath = true
        e.subagent = true
        return e
    }

    func testRoundTripsWhatTheReportUses() throws {
        let files = ["/a.jsonl": UsageCache.File(modified: 1_800_000_123.5, events: [event("s1"), event("s2")]),
                     "/b.jsonl": UsageCache.File(modified: 1_800_000_000, events: [])]
        let data = try XCTUnwrap(UsageCache.encode(files, version: "1.2.14"))
        let back = UsageCache.decode(data, version: "1.2.14")
        XCTAssertEqual(back["/a.jsonl"]?.modified, 1_800_000_123.5)
        XCTAssertEqual(back["/b.jsonl"]?.events, [])
        let e = try XCTUnwrap(back["/a.jsonl"]?.events.first)
        let original = event("s1")
        XCTAssertEqual(e.at.timeIntervalSince1970, original.at.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual([e.provider, e.model, e.projectKey, e.sessionID, e.claudeRowKey],
                       [original.provider, original.model, original.projectKey, original.sessionID, original.claudeRowKey])
        XCTAssertEqual([e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite, e.reasoning, e.toolCalls], [10, 20, 30, 40, 5, 3])
        XCTAssertEqual(e.costUSD, 0.25, accuracy: 1e-12)
        XCTAssertEqual([e.isTurn, e.isSidechain, e.isSubagentPath, e.subagent, e.costIncomplete], [true, true, true, true, false])
        XCTAssertEqual(back["/a.jsonl"]?.events.last?.sessionID, "s2")
    }

    func testAnotherVersionOrDamagedDataReadsAsEmpty() throws {
        let data = try XCTUnwrap(UsageCache.encode(["/a.jsonl": .init(modified: 1, events: [event("s")])], version: "1.2.14"))
        XCTAssertTrue(UsageCache.decode(data, version: "1.2.15").isEmpty, "a new build may price differently")
        XCTAssertTrue(UsageCache.decode(Data("junk".utf8), version: "1.2.14").isEmpty)
    }

    func testLeavesOutFilesThatCantBeStoredOrHadUnpricedEvents() throws {
        var tabbed = event("s")
        tabbed.model = "bad\tmodel"
        let files = ["/tab.jsonl": UsageCache.File(modified: 1, events: [tabbed]),
                     "/new\nline.jsonl": UsageCache.File(modified: 1, events: []),
                     "/unpriced.jsonl": UsageCache.File(modified: 1, events: [event("s", cost: 0, incomplete: true)]),
                     "/ok.jsonl": UsageCache.File(modified: 1, events: [event("s")])]
        let back = UsageCache.decode(try XCTUnwrap(UsageCache.encode(files, version: "v")), version: "v")
        XCTAssertEqual(Set(back.keys), ["/ok.jsonl"], "an unpriced event is read again, to pick up a new price")
    }
}
