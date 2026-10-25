import XCTest
@testable import AgTermCore

/// Ported from agmux `src-tauri/src/teams/scan/codex.rs` tests, plus the
/// `CodexUsageFields` tests in `commands/usage_stats.rs`.
final class TeamsCodexTests: XCTestCase {
    func parse(_ lines: String, _ session: String = "s") -> [UsageEvent] {
        CodexTranscript.parse(lines: lines, sessionID: session)
    }

    func line(_ ts: String, _ body: String) -> String {
        #"{"timestamp":"\#(ts)","payload":{\#(body)}}"#
    }

    /// Closes a turn so pending tool calls flush into an event.
    func usage(_ ts: String, _ input: Int) -> String {
        line(ts, #""model":"gpt-5-codex","info":{"last_token_usage":{"input_tokens":\#(input)}}"#)
    }

    func testOriginatorIsReadFromTheSessionMetaHeader() {
        for originator in ["agmux", "xanom", "codex-tui", "codex_exec", "codex_work_desktop", ""] {
            let meta = jsonLine(["type": "session_meta", "payload": ["id": "native-chat", "originator": originator, "source": "cli"]])
            XCTAssertEqual(CodexTranscript.originator(header: meta), originator)
        }
        XCTAssertNil(CodexTranscript.originator(header: #"{"type":"response_item","payload":{"originator":"agmux"}}"#))
        XCTAssertNil(CodexTranscript.originator(header: "not json"))
    }

    func testCountsToolCallsByKind() {
        let lines = [
            line("2026-07-29T14:00:00Z", #""type":"function_call","name":"exec_command""#),
            line("2026-07-29T14:00:01Z", #""type":"custom_tool_call","name":"apply_patch""#),
            line("2026-07-29T14:00:02Z", #""type":"function_call","name":"spawn_agent""#),
            usage("2026-07-29T14:00:03Z", 10),
        ].joined(separator: "\n")
        let e = parse(lines)[0]
        XCTAssertEqual(e.tools.bash, 1)
        XCTAssertEqual(e.tools.edit, 1)
        XCTAssertEqual(e.tools.agent, 1)
        XCTAssertEqual(e.toolCalls, 3)
    }

    func testPatchApplyEndSuppliesTheLineCounts() {
        let changes = #"{"/w/a.rs":{"type":"update","unified_diff":"--- a/a.rs\n+++ b/a.rs\n@@\n-old\n+new\n+extra\n"},"/w/b.md":{"type":"add","content":"x\ny\nz"}}"#
        let lines = [line("2026-07-29T14:00:00Z", #""type":"patch_apply_end","success":true,"changes":\#(changes)"#),
                     usage("2026-07-29T14:00:01Z", 10)].joined(separator: "\n")
        let e = parse(lines)[0]
        XCTAssertEqual(e.tools.filesChanged, 2)
        XCTAssertEqual(e.tools.linesAdded, 5, "2 from the diff + 3 from the new file")
        XCTAssertEqual(e.tools.linesRemoved, 1)
        XCTAssertEqual(e.tools.measured, 1)
        XCTAssertEqual(e.tools.errors, 0)
    }

    func testFileChangeItemsSupplyTheLineCountsLikePatchApplyEnd() {
        func item(_ id: String, _ status: String) -> String {
            jsonLine(["timestamp": "2026-07-29T14:00:00Z", "type": "event_msg", "payload": [
                "type": "item_completed", "thread_id": "s", "turn_id": "t",
                "item": ["type": "FileChange", "id": id, "status": status, "changes": [
                    "/w/a.rs": ["type": "update", "unified_diff": "@@ -1 +1,2 @@\n-old\n+new\n+extra\n", "move_path": NSNull()],
                    "/w/b.md": ["type": "add", "content": "x\ny\nz"],
                    "/w/c.txt": ["type": "delete", "content": "gone\ntoo"]]]]])
        }
        let lines = [item("call-1", "completed"), item("call-1", "completed"), item("call-2", "declined"),
                     usage("2026-07-29T14:00:01Z", 10)].joined(separator: "\n")
        let e = parse(lines)[0]
        XCTAssertEqual(e.tools.filesChanged, 3, "a repeated item is one edit")
        XCTAssertEqual([e.tools.linesAdded, e.tools.linesRemoved], [5, 3])
        XCTAssertEqual([e.tools.measured, e.tools.errors], [2, 1])
        XCTAssertEqual(e.toolCalls, 0, "the edit's tool call is counted from its call record")
    }

    func testAFailedPatchIsAnErrorAndChangesNothing() {
        let lines = [line("2026-07-29T14:00:00Z", #""type":"patch_apply_end","success":false,"changes":{"/w/a.rs":{"type":"add","content":"a\nb"}}"#),
                     usage("2026-07-29T14:00:01Z", 10)].joined(separator: "\n")
        let e = parse(lines)[0]
        XCTAssertEqual([e.tools.errors, e.tools.measured], [1, 1])
        XCTAssertEqual(e.tools.linesAdded, 0, "a failed patch wrote nothing")
        XCTAssertEqual(e.tools.filesChanged, 0)
    }

    func testPlainToolCallsDoNotInflateTheErrorDenominator() {
        let lines = [line("2026-07-29T14:00:00Z", #""type":"function_call","name":"exec_command""#),
                     usage("2026-07-29T14:00:01Z", 10)].joined(separator: "\n")
        let e = parse(lines)[0]
        XCTAssertEqual(e.tools.bash, 1)
        XCTAssertEqual(e.tools.measured, 0, "an unobservable outcome is not a success")
    }

    func testToolCallsAfterTheLastUsageLineAreStillCredited() {
        let lines = [usage("2026-07-29T14:00:00Z", 10),
                     line("2026-07-29T14:00:05Z", #""type":"function_call","name":"exec_command""#)].joined(separator: "\n")
        let events = parse(lines)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].toolCalls, 1)
    }

    func testParsesPerTurnUsageIncludingReasoning() {
        let l = line("2026-07-29T14:05:00Z", #""cwd":"/Users/neel/code/helios-api","model":"gpt-5.6-sol","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":50,"cached_input_tokens":900,"cache_write_input_tokens":10,"reasoning_output_tokens":40}}"#)
        let e = parse(l, "sess-1")[0]
        XCTAssertEqual(e.provider, "Codex")
        XCTAssertEqual(e.model, "gpt-5.6-sol")
        XCTAssertEqual(e.projectKey, "helios-api")
        XCTAssertEqual([e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite], [90, 50, 900, 10], "tokens_in is uncached")
        XCTAssertEqual(e.reasoning, 40)
        let expected = 90.0 / 1e6 * 4.0 + 900.0 / 1e6 * 0.40 + 10.0 / 1e6 * 5.0 + 50.0 / 1e6 * 20.0
        XCTAssertEqual(e.costUSD, expected, accuracy: 1e-9)
    }

    func testPureInputSubtractsCacheFromOpenAIInclusiveInput() {
        let l = line("2026-07-29T14:05:00Z", #""cwd":"/Users/neel/code/helios-api","model":"gpt-5.6-sol","info":{"last_token_usage":{"input_tokens":17879,"output_tokens":363,"cached_input_tokens":11008,"cache_write_input_tokens":0,"reasoning_output_tokens":101}}"#)
        let e = parse(l, "sess-1")[0]
        XCTAssertEqual(e.tokensIn, 17879 - 11008)
        XCTAssertEqual(e.cacheRead, 11008)
        XCTAssertEqual(e.tokensOut, 363)
        XCTAssertEqual(e.reasoning, 101)
        let expected = Double(17879 - 11008) / 1e6 * 4.0 + 11008.0 / 1e6 * 0.40 + 363.0 / 1e6 * 20.0
        XCTAssertEqual(e.costUSD, expected, accuracy: 1e-9)
    }

    func usageRow(_ model: String, write: Int?) -> String {
        var usage: [String: Any] = ["input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 100, "reasoning_output_tokens": 80]
        if let write { usage["cache_write_input_tokens"] = write }
        return jsonLine(["timestamp": "2026-09-08T14:00:00Z", "payload": ["model": model, "info": ["last_token_usage": usage]]])
    }

    func testWritePricedModelsRequireReportedWriteCounters() {
        let missing = (Array(repeating: usageRow("gpt-5.6-sol", write: nil), count: 432)
            + Array(repeating: usageRow("gpt-5.6-luna", write: nil), count: 14)).joined(separator: "\n")
        let events = parse(missing)
        XCTAssertEqual(events.count, 446)
        XCTAssertTrue(events.allSatisfy { $0.costIncomplete && $0.costUSD == 0 })
        for model in ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra"] {
            let zero = parse(usageRow(model, write: 0))
            XCTAssertFalse(zero[0].costIncomplete, "explicit zero is reported: \(model)")
            XCTAssertGreaterThan(zero[0].costUSD, 0, "known model: \(model)")
            let w = parse(usageRow(model, write: 150))[0]
            XCTAssertEqual([w.tokensIn, w.cacheRead, w.cacheWrite], [50, 800, 150])
            XCTAssertEqual(w.tokensIn + w.cacheRead + w.cacheWrite + w.tokensOut, 1100)
            XCTAssertEqual(w.reasoning, 80)
        }
    }

    func testCumulativeWriteBucketsSurviveDeltasWithoutDoubleCounting() {
        func row(_ n: Int) -> String {
            jsonLine(["timestamp": "2026-09-08T14:00:00Z", "payload": ["model": "gpt-6-astra", "info": [
                "last_token_usage": ["input_tokens": 1000, "cached_input_tokens": 800, "cache_write_input_tokens": 150,
                                     "output_tokens": 100, "reasoning_output_tokens": 80],
                "total_token_usage": ["input_tokens": 1000 * n, "cached_input_tokens": 800 * n, "cache_write_input_tokens": 150 * n,
                                      "output_tokens": 100 * n, "reasoning_output_tokens": 80 * n]]]])
        }
        let events = parse([row(1), row(1), row(2)].joined(separator: "\n"))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.cacheWrite).reduce(0, +), 300)
        XCTAssertEqual(events.map { $0.tokensIn + $0.cacheRead + $0.cacheWrite + $0.tokensOut }.reduce(0, +), 2200)
        XCTAssertTrue(events.allSatisfy { !$0.costIncomplete && $0.costUSD > 0 })
    }

    func testCumulativeOnlyAndUnknownModelsKeepTokensButNotAPrice() {
        let payloads: [[String: Any]] = [
            ["model": "gpt-6-astra", "info": ["total_token_usage": ["input_tokens": 300_000, "cache_write_input_tokens": 0, "output_tokens": 100]]],
            ["model": "unknown-audit-model", "info": ["last_token_usage": ["input_tokens": 300_000, "cache_write_input_tokens": 0, "output_tokens": 100]]],
            ["info": ["last_token_usage": ["input_tokens": 300_000, "cache_write_input_tokens": 0, "output_tokens": 100]]],
        ]
        for payload in payloads {
            let events = parse(jsonLine(["timestamp": "2026-09-08T14:00:00Z", "payload": payload]))
            XCTAssertEqual(events[0].tokensIn + events[0].tokensOut, 300_100)
            XCTAssertTrue(events[0].costIncomplete)
            XCTAssertEqual(events[0].costUSD, 0)
            if payload["model"] == nil { XCTAssertTrue(events[0].model.isEmpty) }
        }
    }

    func testAccountingAuditPricesEachRequestWithItsModel() {
        func row(_ model: String, _ total: Int) -> String {
            jsonLine(["timestamp": "2026-07-29T14:05:00Z", "payload": ["model": model, "info": [
                "last_token_usage": ["input_tokens": 160_000, "cached_input_tokens": 150_000, "cache_write_input_tokens": 0,
                                     "output_tokens": 100, "reasoning_output_tokens": 80],
                "total_token_usage": ["input_tokens": 160_000 * total, "cached_input_tokens": 150_000 * total,
                                      "cache_write_input_tokens": 0, "output_tokens": 100 * total, "reasoning_output_tokens": 80 * total]]]])
        }
        let events = parse([row("gpt-5.6-sol", 1), row("gpt-5.6-sol", 1), row("gpt-5.6-sol", 2)].joined(separator: "\n"))
        XCTAssertEqual(events.count, 2)
        // 320k cumulative input must not charge the >272k request tier.
        let perRequest = (10000.0 * 4.0 + 150000.0 * 0.4 + 100.0 * 20.0) / 1e6
        XCTAssertEqual(events.map(\.costUSD).reduce(0, +), 2 * perRequest, accuracy: 1e-9)
        let changed = parse([row("gpt-5.6-sol", 1), row("gpt-5.4-mini", 2)].joined(separator: "\n"))
        XCTAssertEqual(changed[0].model, "gpt-5.6-sol")
        XCTAssertEqual(changed[1].model, "gpt-5.4-mini")
        XCTAssertLessThan(changed[1].costUSD, changed[0].costUSD)
    }

    func testDifferencesACumulativeTotalInsteadOfSummingIt() {
        let a = line("2026-07-29T14:00:00Z", #""model":"gpt-5.6-sol","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10}}"#)
        let b = line("2026-07-29T14:05:00Z", #""model":"gpt-5.6-sol","info":{"total_token_usage":{"input_tokens":300,"output_tokens":40}}"#)
        let events = parse("\(a)\n\(b)")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].tokensIn, 100)
        XCTAssertEqual(events[1].tokensIn, 200, "second event is the delta")
    }

    func testExplicitZeroResetCountsTotalOnlyUsageInEachSegment() {
        let lines = [500, 0, 20, 20, 0, 20, 40].enumerated().map { i, input in
            line(String(format: "2026-07-29T14:00:%02dZ", i), #""info":{"total_token_usage":{"input_tokens":\#(input)}}"#)
        }.joined(separator: "\n")
        let events = parse(lines)
        XCTAssertEqual(events.map(\.tokensIn).reduce(0, +), 560)
        XCTAssertEqual(events.count, 4)
    }

    func testExplicitZeroResetCountsEqualResponseTotalsInNewSegment() {
        var counter = CodexSessionCounter()
        let usage = CodexUsageFields(input: 500, cached: 400, output: 20, reasoning: 5)
        for _ in 0..<2 {
            XCTAssertEqual(counter.apply(last: usage, total: usage), usage)
            XCTAssertNil(counter.apply(last: usage, total: usage))
            XCTAssertNil(counter.apply(last: CodexUsageFields(), total: CodexUsageFields()))
        }
    }

    func testPrefersPerTurnOverCumulativeWhenBothArePresent() {
        let l = line("2026-07-29T14:00:00Z", #""info":{"last_token_usage":{"input_tokens":7},"total_token_usage":{"input_tokens":9999}}"#)
        XCTAssertEqual(parse(l)[0].tokensIn, 7)
    }

    func testUsesCacheReadInputTokensWhenCachedInputTokensIsAbsent() {
        let l = line("2026-07-29T14:05:00Z", #""model":"gpt-5.6-sol","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":10,"cache_read_input_tokens":400}}"#)
        let e = parse(l)[0]
        XCTAssertEqual([e.tokensIn, e.cacheRead, e.tokensOut], [600, 400, 10])
    }

    func testPrefersTheLargerOfTheTwoCacheAliases() {
        let l = line("2026-07-29T14:05:00Z", #""model":"gpt-5.6-sol","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_read_input_tokens":400,"output_tokens":1}}"#)
        let e = parse(l)[0]
        XCTAssertEqual([e.tokensIn, e.cacheRead], [600, 400])
    }

    func forkHeader(_ extra: [String: Any] = [:]) -> String {
        var payload: [String: Any] = ["id": "child", "session_id": "parent", "forked_from_id": "parent",
                                      "timestamp": "2026-07-29T14:01:00Z",
                                      "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]]
        payload.merge(extra) { _, new in new }
        return jsonLine(["type": "session_meta", "payload": payload])
    }

    func testSubagentAndAutoReviewThreadsAreFlaggedButUserForksAreNot() {
        let usage = jsonLine(["timestamp": "2026-07-29T14:02:00Z", "payload": ["info": [
            "last_token_usage": ["input_tokens": 10], "total_token_usage": ["input_tokens": 10]]]])
        func header(_ source: Any) -> String { jsonLine(["type": "session_meta", "payload": ["id": "s", "source": source]]) }
        let cases: [(Any, Bool)] = [
            (["subagent": ["thread_spawn": ["parent_thread_id": "p"]]], true),
            (["subagent": ["other": "guardian"]], true),
            ("cli", false),
            ("exec", false),
        ]
        for (source, expected) in cases {
            let events = parse("\(header(source))\n\(usage)")
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].subagent, expected)
        }
        // Copied ancestor headers never change the first header's identity.
        let copied = header(["subagent": ["other": "guardian"]])
        XCTAssertFalse(parse("\(header("cli"))\n\(copied)\n\(usage)")[0].subagent)
        XCTAssertTrue(parse("\(forkHeader())\n\(usage)", "child").allSatisfy(\.subagent))
    }

    func testNativeResponseRecordsPreserveOwnWorkAndReplaceLegacyTurnMirrors() {
        let header = jsonLine(["type": "session_meta", "payload": ["id": "child", "forked_from_id": "parent",
                                                                   "timestamp": "2026-07-29T14:00:00Z", "subagent_history_start_ordinal": 100]])
        let usage: [String: Any] = ["input_tokens": 30, "output_tokens": 10]
        let native = jsonLine(["type": "token_usage_record", "ordinal": 50, "timestamp": "2026-07-29T14:02:00Z",
                               "payload": ["thread_id": "child", "turn_id": "own-turn", "response_id": "response-1", "usage": usage,
                                           "thread_token_usage": ["input_tokens": 10030, "output_tokens": 10010]]])
        let outside = jsonLine(["type": "token_usage_record", "ordinal": 51, "timestamp": "2026-07-29T14:02:00Z",
                                "payload": ["thread_id": "parent", "turn_id": "parent-turn", "response_id": "parent-response",
                                            "usage": ["input_tokens": 500]]])
        let context = jsonLine(["type": "turn_context", "payload": ["turn_id": "own-turn", "model": "gpt-5"]])
        let legacy = jsonLine(["type": "event_msg", "ordinal": 101, "timestamp": "2026-07-29T14:02:00Z",
                               "payload": ["type": "token_count", "info": ["last_token_usage": usage, "total_token_usage": usage]]])
        for rows in [[header, context, native, native, outside, legacy], [header, context, legacy, native, outside]] {
            let parsed = parse(rows.joined(separator: "\n"), "child")
            XCTAssertEqual(parsed.map { $0.tokensIn + $0.tokensOut }.reduce(0, +), 40)
            XCTAssertEqual(parsed.count, 1)
        }
        let only = parse([header, context, native].joined(separator: "\n"), "child")
        XCTAssertEqual(only.map { $0.tokensIn + $0.tokensOut }.reduce(0, +), 40)
    }

    func testPaginatedChildCountsOnlyOwnOrdinalsEvenWhenHistoryIsRetimestamped() {
        var rows = [forkHeader(["history_mode": "paginated", "subagent_history_start_ordinal": 10])]
        for (ordinal, total, last) in [(5, 1000, 0), (8, 1100, 100), (10, 1130, 30)] {
            rows.append(jsonLine(["type": "event_msg", "ordinal": ordinal, "timestamp": "2026-07-29T14:02:00Z",
                                  "payload": ["type": "token_count", "info": [
                                      "total_token_usage": ["input_tokens": total], "last_token_usage": ["input_tokens": last]]]]))
        }
        let parsed = parse(rows.joined(separator: "\n"), "child")
        XCTAssertEqual(parsed.map(\.tokensIn).reduce(0, +), 30)
        XCTAssertEqual(parsed.count, 1)
    }

    /// agmux passes the parent's final watermark here; it is deliberately unused.
    func testForkSubagentCountsOwnUsageBelowParentFinalWatermark() {
        let child = CodexTranscript.parseDetailed(lines: "\(forkHeader())\n\(usage("2026-07-29T14:02:00Z", 50))", sessionID: "child")
        XCTAssertEqual(child.events.count, 1)
        XCTAssertEqual(child.events[0].tokensIn, 50)
        XCTAssertEqual(child.events[0].sessionID, "child")
    }

    func testForkUsesItsCopiedPrefixNotLaterParentWork() {
        let copied = line("2026-07-29T14:00:00Z", #""info":{"last_token_usage":{"input_tokens":100},"total_token_usage":{"input_tokens":100}}"#)
        let unique = line("2026-07-29T14:02:00Z", #""info":{"last_token_usage":{"input_tokens":50},"total_token_usage":{"input_tokens":150}}"#)
        let child = parse([forkHeader(), copied, unique].joined(separator: "\n"), "child")
        XCTAssertEqual(child.count, 1)
        XCTAssertEqual(child[0].tokensIn, 50)
    }

    func testForkWithFreshCumulativeCountersCountsFirstAndRepeatedEventsOnce() {
        let first = line("2026-07-29T14:02:00Z", #""info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":4},"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":4}}"#)
        let child = parse([forkHeader(), first, first].joined(separator: "\n"), "child")
        XCTAssertEqual(child.count, 1)
        XCTAssertEqual([child[0].tokensIn, child[0].cacheRead, child[0].tokensOut, child[0].reasoning], [20, 80, 10, 4])
    }

    func testCopiedForkMetadataCannotReplaceChildIdentityOrCutoff() {
        let parent = jsonLine(["type": "session_meta", "payload": ["id": "parent", "forked_from_id": "grandparent",
                                                                   "timestamp": "2026-07-29T14:00:00Z"]])
        let copied = line("2026-07-29T14:00:30Z", #""info":{"total_token_usage":{"input_tokens":100},"last_token_usage":{"input_tokens":100}}"#)
        let own = line("2026-07-29T14:02:00Z", #""info":{"total_token_usage":{"input_tokens":150},"last_token_usage":{"input_tokens":50}}"#)
        let parsed = CodexTranscript.parseDetailed(lines: [forkHeader(), parent, copied, own].joined(separator: "\n"), sessionID: "child")
        XCTAssertEqual(parsed.sessionID, "child")
        XCTAssertEqual(parsed.forkedFromID, "parent")
        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events[0].sessionID, "child")
        XCTAssertEqual(parsed.events[0].tokensIn, 50)
    }

    func testCopiedForkMetadataCannotAddLineageToNonforkHeader() {
        let root = jsonLine(["type": "session_meta", "payload": ["id": "root"]])
        let parsed = CodexTranscript.parseDetailed(lines: [root, forkHeader(), usage("2026-07-29T14:00:00Z", 50)].joined(separator: "\n"),
                                                   sessionID: "root")
        XCTAssertEqual(parsed.sessionID, "root")
        XCTAssertNil(parsed.forkedFromID)
        XCTAssertEqual(parsed.events[0].tokensIn, 50)
    }

    func testSkipsLinesWithoutTokenInfo() {
        XCTAssertTrue(parse(line("2026-07-29T14:00:00Z", #""type":"event_msg""#)).isEmpty)
    }

    func testToleratesMalformedLines() {
        let good = line("2026-07-29T14:00:00Z", #""info":{"last_token_usage":{"input_tokens":5}}"#)
        XCTAssertEqual(parse("garbage\n\(good)").count, 1)
    }

    func testNeverEmitsAPathAsTheProjectKey() {
        let l = line("2026-07-29T14:00:00Z", #""cwd":"/Users/neel/secret/thing","info":{"last_token_usage":{"input_tokens":5}}"#)
        let e = parse(l)[0]
        XCTAssertEqual(e.projectKey, "thing")
        XCTAssertFalse(e.projectKey.contains("/"))
    }

    func testExtractsTheSessionUUIDFromARolloutFilename() {
        XCTAssertEqual(CodexTranscript.sessionID(fromPath: "/x/rollout-2026-07-29T14-00-00-0199c7f0-1111-2222-3333-444455556666.jsonl"),
                       "0199c7f0-1111-2222-3333-444455556666")
    }

    // MARK: - CodexUsageFields (usage_stats.rs)

    func fields(_ json: String) -> CodexUsageFields { CodexUsageFields(JSONValue.parse(json)) }

    func testCodexFieldsUseLargerCacheAlias() {
        let f = fields(#"{"input_tokens":1000,"cached_input_tokens":100,"cache_read_input_tokens":400,"output_tokens":20}"#)
        XCTAssertEqual(f.cached, 400)
        XCTAssertEqual([f.splitInput.uncached, f.splitInput.cached, f.splitInput.cacheWrite], [600, 400, 0])
    }

    func testCodexFieldsSplitTreatsWritesAsSubsetOfUncached() {
        let f = fields(#"{"input_tokens":1000,"cached_input_tokens":900,"cache_write_input_tokens":10,"output_tokens":50,"reasoning_output_tokens":40}"#)
        XCTAssertEqual([f.splitInput.uncached, f.splitInput.cached, f.splitInput.cacheWrite], [90, 900, 10])
        XCTAssertEqual(f.reasoning, 40)
    }

    func testCodexFieldsCapReasoningAtOutput() {
        XCTAssertEqual(fields(#"{"input_tokens":10,"output_tokens":5,"reasoning_output_tokens":50}"#).reasoning, 5)
    }
}
