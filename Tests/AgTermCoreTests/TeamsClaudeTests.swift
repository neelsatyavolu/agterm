import XCTest
@testable import AgTermCore

/// Serialises a fixture object to one JSON line.
func jsonLine(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        XCTFail("unserialisable fixture")
        return ""
    }
    return String(decoding: data, as: UTF8.self)
}

/// Ported from agmux `src-tauri/src/teams/scan/claude.rs` tests.
final class TeamsClaudeTests: XCTestCase {
    func parse(_ lines: String, _ session: String = "s", _ dir: String = "") -> [UsageEvent] {
        ClaudeTranscript.parse(lines: lines, sessionID: session, fallbackDir: dir)
    }

    func usageLine(_ output: Int, _ timestamp: String, model: String = "claude-sonnet-4-6", request: String = "req-1") -> String {
        jsonLine(["type": "assistant", "timestamp": timestamp, "requestId": request,
                  "message": ["id": "msg-1", "model": model, "usage": ["input_tokens": 100, "output_tokens": output]]])
    }

    func testForkCopiesKeepCompleteUsageIndependentOfScanOrder() {
        let partial = usageLine(2, "2026-07-29T14:05:00Z")
        let complete = usageLine(50, "2026-07-29T14:05:01Z")
        for reverse in [false, true] {
            var events = parse(partial, "parent", "/proj") + parse(complete, "fork", "/proj")
            if reverse { events.reverse() }
            events = ClaudeTranscript.reconcile(events)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].tokensOut, 50)
            XCTAssertEqual(events[0].at, TeamsTime.parse("2026-07-29T14:05:01Z"))
        }
    }

    func testEqualForkCopiesHaveStableAttribution() {
        let line = usageLine(50, "2026-07-29T14:05:00Z")
        for reverse in [false, true] {
            var events = parse(line, "a", "/proj") + parse(line, "b", "/proj")
            if reverse { events.reverse() }
            events = ClaudeTranscript.reconcile(events)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].sessionID, "a")
        }
    }

    func testZeroTailDoesNotEraseReportedUsage() {
        let line = usageLine(50, "2026-07-29T14:59:59Z")
        let zero = jsonLine(["type": "assistant", "timestamp": "2026-07-29T15:00:00Z", "requestId": "req-1",
                             "message": ["id": "msg-1", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 0, "output_tokens": 0]]])
        let events = parse("\(line)\n\(zero)")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual([events[0].tokensIn, events[0].tokensOut], [100, 50])
        XCTAssertEqual(events[0].at, TeamsTime.parse("2026-07-29T14:59:59Z"))
    }

    func testStreamCompletionUsesItsOwnHourAndRequestIdentity() {
        let first = usageLine(2, "2026-07-29T14:59:59Z")
        let last = usageLine(50, "2026-07-29T15:00:01Z")
        let events = parse("\(first)\n\(last)")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].at, TeamsTime.parse("2026-07-29T15:00:01Z"))
        let distinct = usageLine(50, "2026-07-29T15:00:01Z", request: "req-2")
        XCTAssertEqual(parse("\(last)\n\(distinct)").count, 2)
    }

    func testUnknownPricePreservesClaudeTokensAndMarksCostIncomplete() {
        let known = parse(usageLine(50, "2026-07-29T14:05:00Z"))
        XCTAssertFalse(known[0].costIncomplete)
        XCTAssertGreaterThan(known[0].costUSD, 0)
        let unknown = parse(usageLine(50, "2026-07-29T14:05:00Z", model: "unknown-audit-model"))
        XCTAssertEqual(unknown[0].tokensIn + unknown[0].tokensOut, 150)
        XCTAssertTrue(unknown[0].costIncomplete)
        XCTAssertEqual(unknown[0].costUSD, 0)
    }

    func testAccountingAuditPricesRequestsNotTheSessionSum() {
        func row(_ request: String, _ output: Int) -> String {
            jsonLine(["type": "assistant", "timestamp": "2026-07-29T14:05:00Z", "requestId": request,
                      "message": ["id": request, "model": "claude-sonnet-4-5", "usage": [
                          "input_tokens": 10000, "cache_read_input_tokens": 140000, "cache_creation_input_tokens": 10000,
                          "output_tokens": output,
                          "cache_creation": ["ephemeral_5m_input_tokens": 5000, "ephemeral_1h_input_tokens": 5000]]]])
        }
        let events = parse([row("a", 1), row("a", 100), row("b", 100)].joined(separator: "\n"))
        XCTAssertEqual(events.count, 2)
        // Each prompt is 160k; their 320k sum must not trigger a long-context tier.
        let perRequest = (10000.0 * 3.0 + 140000.0 * 0.3 + 5000.0 * 3.75 + 5000.0 * 6.0 + 100.0 * 15.0) / 1e6
        XCTAssertEqual(events.map(\.costUSD).reduce(0, +), 2 * perRequest, accuracy: 1e-9)
    }

    func testMixedCacheLifetimesDoNotDoubleCountTokens() {
        let line = jsonLine(["timestamp": "2026-07-29T14:05:00Z", "message": ["model": "claude-sonnet-4-6", "usage": [
            "input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000,
            "cache_creation_input_tokens": 2_000_000,
            "cache_creation": ["ephemeral_5m_input_tokens": 1_000_000, "ephemeral_1h_input_tokens": 1_000_000]]]])
        let event = parse(line)[0]
        XCTAssertEqual(event.cacheWrite, 2_000_000)
        XCTAssertEqual(event.costUSD, 3.0 + 15.0 + 0.3 + 3.75 + 6.0, accuracy: 1e-9)
    }

    static let line = #"{"timestamp":"2026-07-29T14:05:00Z","cwd":"/Users/neel/code/helios-api","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":900,"cache_creation_input_tokens":20},"content":[{"type":"text"},{"type":"tool_use"},{"type":"tool_use"}]}}"#

    func testParsesARealAssistantMessage() {
        let e = parse(Self.line, "sess-1", "/fallback/dir")[0]
        XCTAssertEqual(e.provider, "ClaudeCode")
        XCTAssertEqual(e.model, "claude-opus-5")
        XCTAssertEqual(e.projectKey, "helios-api")
        XCTAssertEqual(e.sessionID, "sess-1")
        XCTAssertEqual([e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite], [100, 50, 900, 20])
        XCTAssertEqual(e.toolCalls, 2)
        XCTAssertTrue(e.isTurn)
        XCTAssertGreaterThan(e.costUSD, 0, "opus usage should cost something")
    }

    func testUsesTheEventsOwnTimestampNotScanTime() {
        XCTAssertEqual(TeamsTime.hourKey(parse(Self.line)[0].at), "2026-07-29T14")
    }

    func testSkipsLinesWithoutUsage() {
        let user = #"{"timestamp":"2026-07-29T14:00:00Z","type":"user","message":{"role":"user"}}"#
        XCTAssertEqual(parse("\(user)\n\(Self.line)").count, 1)
    }

    func testSkipsSyntheticAndBlankModels() {
        XCTAssertTrue(parse(#"{"timestamp":"2026-07-29T14:00:00Z","message":{"model":"<synthetic>","usage":{"input_tokens":10}}}"#).isEmpty)
        XCTAssertTrue(parse(#"{"timestamp":"2026-07-29T14:00:00Z","message":{"usage":{"input_tokens":10}}}"#).isEmpty)
    }

    func testSkipsZeroTokenUsageBlocks() {
        XCTAssertTrue(parse(#"{"timestamp":"2026-07-29T14:00:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0}}}"#).isEmpty)
    }

    func testToleratesMalformedLines() {
        XCTAssertEqual(parse("not json\n\n\(Self.line)\n{\"broken\":").count, 1)
    }

    func testFallsBackToTheDirectoryWhenALineHasNoCwd() {
        let noCwd = #"{"timestamp":"2026-07-29T14:00:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10}}}"#
        XCTAssertEqual(parse(noCwd, "s", "/Users/neel/code/other-repo")[0].projectKey, "other-repo")
    }

    func testNeverEmitsAPathAsTheProjectKey() {
        let e = parse(Self.line)[0]
        XCTAssertFalse(e.projectKey.contains("/"))
        XCTAssertFalse(e.projectKey.contains("Users"))
    }

    static let withTools = #"{"timestamp":"2026-07-29T14:05:00Z","cwd":"/w/repo","message":{"model":"claude-opus-5","usage":{"input_tokens":100},"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/w/repo/a.rs","old_string":"one\ntwo","new_string":"one\ntwo\nthree"}},{"type":"tool_use","name":"mcp__memory__add","input":{}}]}}"#

    func testClassifiesToolCallsByKind() {
        let e = parse(Self.withTools)[0]
        XCTAssertEqual(e.tools.bash, 1)
        XCTAssertEqual(e.tools.edit, 1)
        XCTAssertEqual(e.tools.mcp, 1)
        XCTAssertEqual(e.toolCalls, 3, "tool_calls stays the sum of the kinds")
    }

    func testMeasuresEditSizeWithoutKeepingTheText() {
        let e = parse(Self.withTools)[0]
        XCTAssertEqual(e.tools.linesAdded, 3)
        XCTAssertEqual(e.tools.linesRemoved, 2)
        XCTAssertEqual(e.tools.filesChanged, 1)
    }

    func testAWriteCountsOnlyAddedLines() {
        let write = #"{"timestamp":"2026-07-29T14:05:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10},"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/w/x.rs","content":"a\nb\nc"}}]}}"#
        let e = parse(write)[0]
        XCTAssertEqual([e.tools.linesAdded, e.tools.linesRemoved], [3, 0])
        XCTAssertEqual(e.tools.filesChanged, 1)
    }

    func testToolErrorsAttachToTheTurnThatIssuedThem() {
        let results = #"{"timestamp":"2026-07-29T14:05:30Z","type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"},{"type":"tool_result","content":"fine"}]}}"#
        let events = parse("\(Self.withTools)\n\(results)")
        XCTAssertEqual(events.count, 1, "a tool_result line carries no usage of its own")
        XCTAssertEqual(events[0].tools.errors, 1)
        XCTAssertEqual(events[0].tools.measured, 2, "both results were observable")
    }

    func testResultsBeforeTheFirstUsageLineAreNotDropped() {
        let early = #"{"timestamp":"2026-07-29T14:04:00Z","type":"user","message":{"content":[{"type":"tool_result","is_error":true}]}}"#
        let events = parse("\(early)\n\(Self.withTools)")
        XCTAssertEqual(events[0].tools.errors, 1)
        XCTAssertEqual(events[0].tools.measured, 1)
    }

    func testCountsOneTurnPerUsageMessage() {
        let events = parse("\(Self.line)\n\(Self.line.replacingOccurrences(of: "14:05:00", with: "14:06:00"))")
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy(\.isTurn))
    }

    func testStreamingChunksKeepTheLastCumulativeUsage() {
        let first = #"{"type":"assistant","timestamp":"2026-07-29T14:05:00Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":2}}}"#
        let last = #"{"type":"assistant","timestamp":"2026-07-29T14:05:01Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20}}}"#
        let events = parse("\(first)\n\(last)")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual([events[0].tokensIn, events[0].tokensOut, events[0].cacheRead], [100, 50, 20])
    }

    func testParallelToolCallsSplitAcrossLinesAllCount() {
        func block(_ ts: String, _ content: String) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5},"content":[\#(content)]}}"#
        }
        let edit = #"{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"old_string":"a","new_string":"a\nb"}}"#
        let lines = [
            block("2026-07-29T14:05:00Z", #"{"type":"text","text":"hi"}"#),
            block("2026-07-29T14:05:01Z", #"{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}"#),
            #"{"type":"user","timestamp":"2026-07-29T14:05:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true}]}}"#,
            block("2026-07-29T14:05:03Z", edit),
            #"{"type":"user","timestamp":"2026-07-29T14:05:04Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2"}]}}"#,
        ].joined(separator: "\n")
        let events = parse(lines)
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual([e.toolCalls, e.tools.bash, e.tools.edit], [2, 1, 1])
        XCTAssertEqual([e.tools.measured, e.tools.errors], [2, 1])
        XCTAssertEqual([e.tools.filesChanged, e.tools.linesAdded, e.tools.linesRemoved], [1, 2, 1])
        XCTAssertEqual([e.tokensIn, e.tokensOut], [10, 5])
        // A repeated copy of a block is still one call.
        XCTAssertEqual(parse("\(lines)\n\(block("2026-07-29T14:05:05Z", edit))")[0].toolCalls, 2)
    }

    func testSkipsNonAssistantUsageWhenTypeIsPresent() {
        XCTAssertTrue(parse(#"{"type":"user","timestamp":"2026-07-29T14:05:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":999}}}"#).isEmpty)
    }

    func testOneHourCacheCostsTwiceInputNotWrite() {
        let line = #"{"timestamp":"2026-07-29T14:05:00Z","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000}}}}"#
        XCTAssertEqual(parse(line)[0].costUSD, 6.0, accuracy: 1e-9)
    }

    func testParentWinsOverSubagentDuplicate() {
        let line = #"{"type":"assistant","timestamp":"2026-07-29T14:05:00Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10}}}"#
        let both = parse(line, "parent", "/proj") + parse(line, "child", "/proj/subagents")
        XCTAssertEqual(both.count, 2)
        let events = ClaudeTranscript.reconcile(both)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].isSubagentPath)
        XCTAssertEqual(events[0].tokensIn, 100)
    }

    func testSessionIDIsTheFileStem() {
        XCTAssertEqual(ClaudeTranscript.sessionID(fromPath: "/p/-Users-x/0199c7f0-1111.jsonl"), "0199c7f0-1111")
    }
}
