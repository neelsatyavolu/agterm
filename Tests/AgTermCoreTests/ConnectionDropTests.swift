@testable import AgTermCore
import XCTest

final class ConnectionDropTests: XCTestCase {
    /// Copied from a real transcript (Claude Code 2.1.319), trimmed.
    private let drop = #"{"parentUuid":"a","isSidechain":false,"type":"assistant","timestamp":"2026-11-06T23:45:18.389Z","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"}]},"error":"server_error","isApiErrorMessage":true}"#
    private let since = ISO8601DateFormatter().date(from: "2026-11-06T23:00:00Z")!

    func testRecognizesConnectionErrors() {
        XCTAssertEqual(ConnectionDrop.claude(line: drop)?.message, "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)")
        let lost = drop.replacingOccurrences(of: "Can't reach the API server — check your internet or DNS (ENOTFOUND)",
                                             with: "Connection lost mid-response. The response above may be incomplete.")
        XCTAssertNotNil(ConnectionDrop.claude(line: lost))
        XCTAssertNotNil(ConnectionDrop.claude(line: drop.replacingOccurrences(of: #""isApiErrorMessage":true"#, with: #""apiErrorStatus":null,"isApiErrorMessage":true"#)))
    }

    func testIgnoresAnsweredErrorsAndSubagents() {
        XCTAssertNil(ConnectionDrop.claude(line: drop.replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)))
        XCTAssertNil(ConnectionDrop.claude(line: drop.replacingOccurrences(of: #""isApiErrorMessage":true"#, with: #""apiErrorStatus":500,"isApiErrorMessage":true"#)))
        XCTAssertNil(ConnectionDrop.claude(line: drop.replacingOccurrences(of: "server_error", with: "rate_limit")))
        XCTAssertNil(ConnectionDrop.claude(line: drop.replacingOccurrences(of: #","isApiErrorMessage":true"#, with: "")))
    }

    func testFoldKeepsDropUntilConversationMovesOn() {
        let turnEnd = #"{"type":"system","subtype":"turn_duration","isSidechain":false}"#
        let pending = ConnectionDrop.fold([drop, turnEnd], pending: nil, since: since)
        XCTAssertNotNil(pending)
        // A subagent's line doesn't count; your next message does.
        let sideUser = #"{"isSidechain":true,"type":"user","message":{"content":"x"}}"#
        XCTAssertNotNil(ConnectionDrop.fold([sideUser], pending: pending, since: since))
        let user = #"{"isSidechain":false,"type":"user","message":{"content":"cotninue"}}"#
        XCTAssertNil(ConnectionDrop.fold([user], pending: pending, since: since))
    }

    func testFoldIgnoresDropsFromEarlierRuns() {
        let later = ISO8601DateFormatter().date(from: "2026-11-07T00:00:00Z")!
        XCTAssertNil(ConnectionDrop.fold([drop], pending: nil, since: later))
    }
}
