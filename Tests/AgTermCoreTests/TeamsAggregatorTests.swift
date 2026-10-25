import XCTest
@testable import AgTermCore

/// Ported from agmux `src-tauri/src/teams/aggregate.rs` tests.
final class TeamsAggregatorTests: XCTestCase {
    private let tail = Int(TeamsAggregator.activeTail * 1000)
    private let gapCap = Int(TeamsAggregator.activeGapCap * 1000)

    func ts(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
        guard let date = TeamsTime.parse(s) else {
            XCTFail("bad fixture timestamp \(s)", file: file, line: line)
            return .distantPast
        }
        return date
    }

    func ev(_ at: String) -> UsageEvent {
        UsageEvent(at: ts(at), provider: "ClaudeCode", model: "opus-5", projectKey: "helios-api", sessionID: "s1")
    }

    func build(_ events: [UsageEvent], _ now: String, _ tz: TimeZone = .current) -> [HourlyBucket] {
        TeamsAggregator.buckets(events: events, now: ts(now), timeZone: tz)
    }

    func zone(_ name: String) -> TimeZone { TeamsAggregator.timeZone(named: name) }

    func testIncompleteCostPreservesKnownDollarsAndOldPayloadsRemainUnverified() throws {
        var known = ev("2026-09-08T10:00:00Z")
        known.tokensIn = 100
        known.costUSD = 1.25
        var missing = known
        missing.tokensIn = 200
        missing.costUSD = 0
        missing.costIncomplete = true
        let buckets = build([known, missing], "2026-09-08T11:00:00Z")
        XCTAssertEqual(buckets[0].tokensIn, 300)
        XCTAssertEqual(buckets[0].costUsd, 1.25)
        XCTAssertTrue(buckets[0].costIncomplete)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(buckets[0])) as? [String: Any])
        old.removeValue(forKey: "costIncomplete")
        let decoded = try JSONDecoder().decode(HourlyBucket.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(decoded.costIncomplete)
    }

    func testHourKeyFormatsAsTheServerExpects() {
        XCTAssertEqual(TeamsTime.hourKey(ts("2026-07-29T14:37:12Z")), "2026-07-29T14")
    }

    func testSplitByHourDividesASpanThatStraddlesTheBoundary() {
        let span = Span(start: TeamsTime.micros(ts("2026-07-29T13:50:00Z")), end: TeamsTime.micros(ts("2026-07-29T14:20:00Z")))
        let parts = TeamsAggregator.splitByHour(span)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual((parts[0].1.end - parts[0].1.start) / 60_000_000, 10)
        XCTAssertEqual((parts[1].1.end - parts[1].1.start) / 60_000_000, 20)
    }

    func testSplitByHourRejectsABackwardsOrEmptyRange() {
        let two = TeamsTime.micros(ts("2026-07-29T14:00:00Z"))
        let one = TeamsTime.micros(ts("2026-07-29T13:00:00Z"))
        XCTAssertTrue(TeamsAggregator.splitByHour(Span(start: two, end: one)).isEmpty)
        XCTAssertTrue(TeamsAggregator.splitByHour(Span(start: two, end: two)).isEmpty)
    }

    func testTokensLandInTheHourTheWorkActuallyHappened() {
        var a = ev("2026-07-29T09:15:00Z")
        a.tokensIn = 100
        var b = ev("2026-07-29T15:45:00Z")
        b.tokensIn = 250
        let buckets = build([a, b], "2026-07-29T20:00:00Z")
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].hourUtc, "2026-07-29T09")
        XCTAssertEqual(buckets[0].tokensIn, 100)
        XCTAssertEqual(buckets[1].hourUtc, "2026-07-29T15")
        XCTAssertEqual(buckets[1].tokensIn, 250)
    }

    func testEveryTokenClassIsCarriedIncludingReasoning() {
        var e = ev("2026-07-29T14:00:00Z")
        (e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite, e.reasoning, e.costUSD) = (1, 2, 3, 4, 5, 0.5)
        let b = build([e], "2026-07-29T15:00:00Z")[0]
        XCTAssertEqual([b.tokensIn, b.tokensOut, b.tokensCacheRead, b.tokensCacheWrite, b.tokensReasoning], [1, 2, 3, 4, 5])
        XCTAssertEqual(b.costUsd, 0.5, accuracy: 1e-9)
    }

    func testActiveTimeIsTheGapBetweenEvents() {
        let buckets = build([ev("2026-07-29T14:00:00Z"), ev("2026-07-29T14:02:00Z")], "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets[0].activeMs, 2 * 60_000 + tail)
    }

    func testALongIdleGapDoesNotCountAsActiveTime() {
        let buckets = build([ev("2026-07-29T14:00:00Z"), ev("2026-07-29T17:00:00Z")], "2026-07-29T18:00:00Z")
        XCTAssertEqual(buckets.map(\.activeMs).reduce(0, +), gapCap + tail)
    }

    func testASingleEventSessionGetsOnlyTheShortTail() {
        XCTAssertEqual(build([ev("2026-07-29T14:00:00Z")], "2026-07-29T15:00:00Z")[0].activeMs, tail)
    }

    func testActiveTimeSplitsAcrossTheHourBoundary() {
        let buckets = build([ev("2026-07-29T13:58:00Z"), ev("2026-07-29T14:01:00Z")], "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].activeMs, 2 * 60_000)
        XCTAssertEqual(buckets[1].activeMs, 60_000 + tail)
    }

    func session(_ at: String, _ id: String, provider: String = "ClaudeCode", model: String = "opus-5",
                 project: String = "helios-api") -> UsageEvent {
        var e = ev(at)
        (e.sessionID, e.provider, e.model, e.projectKey) = (id, provider, model, project)
        return e
    }

    func testPeakConcurrencyIsAMaxNotASum() {
        let events = [session("2026-07-29T14:00:00Z", "s1"), session("2026-07-29T14:04:00Z", "s1"),
                      session("2026-07-29T14:02:00Z", "s2"), session("2026-07-29T14:06:00Z", "s2")]
        let buckets = build(events, "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].peakConcurrent, 2)
        XCTAssertEqual(buckets[0].sessions, 2)
    }

    func testPeakConcurrencyCountsOverlappingSessionsInDifferentProjectsAndProviders() {
        let events = [
            session("2026-07-29T14:00:00Z", "s1"), session("2026-07-29T14:04:00Z", "s1"),
            session("2026-07-29T14:01:00Z", "s2", project: "other-repo"), session("2026-07-29T14:05:00Z", "s2", project: "other-repo"),
            session("2026-07-29T14:02:00Z", "s3", provider: "Codex", model: "gpt-5"),
            session("2026-07-29T14:03:00Z", "s3", provider: "Codex", model: "gpt-5"),
        ]
        let buckets = build(events, "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets.count, 3)
        // Dashboards take the max per hour across buckets, so each carries the hour's true peak.
        XCTAssertTrue(buckets.allSatisfy { $0.peakConcurrent == 3 }, "\(buckets)")
    }

    func testSequentialSessionsAreNotConcurrent() {
        let buckets = build([session("2026-07-29T14:00:00Z", "s1"), session("2026-07-29T14:40:00Z", "s2")], "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets[0].peakConcurrent, 1)
        XCTAssertEqual(buckets[0].sessions, 2)
    }

    func testTurnsAndToolCallsAreCounted() {
        var a = ev("2026-07-29T14:00:00Z")
        (a.isTurn, a.toolCalls) = (true, 4)
        var b = ev("2026-07-29T14:01:00Z")
        (b.isTurn, b.toolCalls) = (true, 2)
        let buckets = build([a, b], "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets[0].turns, 2)
        XCTAssertEqual(buckets[0].toolCalls, 6)
    }

    func testToolKindsAndOutputCountersFoldIntoTheBucket() {
        var a = ev("2026-07-29T14:00:00Z")
        a.tools = ToolTally(bash: 2, edit: 1, errors: 1, measured: 3, filesChanged: 1, linesAdded: 20, linesRemoved: 4)
        var b = ev("2026-07-29T14:30:00Z")
        b.tools = ToolTally(bash: 1, read: 5, measured: 6, linesAdded: 3)
        let x = build([a, b], "2026-07-29T15:00:00Z")[0]
        XCTAssertEqual(x.toolBash, 3)
        XCTAssertEqual(x.toolEdit, 1)
        XCTAssertEqual(x.toolRead, 5)
        XCTAssertEqual(x.toolErrors, 1)
        XCTAssertEqual(x.toolsMeasured, 9)
        XCTAssertEqual(x.filesChanged, 1)
        XCTAssertEqual([x.linesAdded, x.linesRemoved], [23, 4])
    }

    func testProvidersAndModelsGetTheirOwnBuckets() {
        let buckets = build([ev("2026-07-29T14:00:00Z"), session("2026-07-29T14:00:00Z", "s1", provider: "Codex", model: "gpt-5.6")],
                            "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].provider, "ClaudeCode")
        XCTAssertEqual(buckets[1].provider, "Codex")
    }

    func testWireLabelCollisionsMergeBeforeAbsoluteUpload() {
        var a = ev("2026-07-29T14:00:00Z")
        (a.model, a.tokensIn) = ("local/model-one", 100)
        var b = a
        (b.model, b.tokensIn, b.sessionID) = ("local/model-two", 200, "s2")
        let buckets = build([a, b], "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].model, "")
        XCTAssertEqual(buckets[0].tokensIn, 300)
        XCTAssertEqual(buckets[0].sessions, 2)
        XCTAssertGreaterThan(buckets[0].activeMs, 0)
    }

    func testWireLabelsStayWithinServerUTF16Limits() {
        let prefix = String(repeating: "🌊", count: 32)
        XCTAssertEqual(TeamsLabels.wireLabel(prefix + "a", maxUnits: 64), prefix)
        XCTAssertEqual(TeamsLabels.wireLabel(String(repeating: "m", count: 61), maxUnits: 60).count, 60)
        XCTAssertEqual(TeamsLabels.wireLabel("/private/path", maxUnits: 60), "")
    }

    func testRepairSessionActivityCountsOncePerProviderSessionHour() {
        let buckets = build([ev("2026-07-29T14:00:00Z"), session("2026-07-29T14:05:00Z", "s1", model: "another-model"),
                             ev("2026-07-29T15:05:00Z")], "2026-07-29T16:00:00Z")
        XCTAssertEqual(buckets.map(\.sessions).reduce(0, +), 2)
    }

    func testSessionsStartedCountsEachTopLevelSessionOnceInItsFirstBucket() {
        // s1 runs across two hours and switches model; it is one session.
        var codexChild = session("2026-07-29T15:31:00Z", "review", provider: "Codex")
        codexChild.subagent = true
        var claudeChild = session("2026-07-29T15:32:00Z", "s1:agent-a")
        claudeChild.isSubagentPath = true
        let events = [ev("2026-07-29T14:00:00Z"), session("2026-07-29T14:05:00Z", "s1", model: "another-model"),
                      ev("2026-07-29T15:05:00Z"), session("2026-07-29T15:30:00Z", "s2"), codexChild, claudeChild]
        let buckets = build(events, "2026-07-29T16:00:00Z")
        func started(_ hour: String, _ model: String) -> Int {
            buckets.filter { $0.hourUtc == hour && $0.model == model }.map { $0.sessionsStarted ?? -100 }.reduce(0, +)
        }
        XCTAssertEqual(started("2026-07-29T14", "opus-5"), 1)
        XCTAssertEqual(started("2026-07-29T14", "another-model"), 0)
        XCTAssertEqual(started("2026-07-29T15", "opus-5"), 1, "only s2 starts in the second hour")
        XCTAssertEqual(buckets.map { $0.sessionsStarted ?? -100 }.reduce(0, +), 2)
        XCTAssertGreaterThan(buckets.map(\.sessions).reduce(0, +), 2, "session-hours still include children")
    }

    func testBatchesQueuedBeforeSessionsStartedStayUnknownOnTheWire() throws {
        let json = #"[{"hourUtc":"2026-07-29T14","provider":"Codex","model":"","projectKey":"","tokensIn":0,"tokensOut":0,"tokensCacheRead":0,"tokensCacheWrite":0,"tokensReasoning":0,"costUsd":0,"activeMs":0,"afterHoursMs":0,"weekendMs":0,"sessions":3,"turns":0,"toolCalls":0,"peakConcurrent":0,"toolBash":0,"toolEdit":0,"toolRead":0,"toolSearch":0,"toolWeb":0,"toolAgent":0,"toolMcp":0,"toolOther":0,"toolErrors":0,"toolsMeasured":0,"filesChanged":0,"linesAdded":0,"linesRemoved":0,"approvalRequests":0,"approvalWaitMs":0,"localHour":0,"localDow":0}]"#
        let old = try JSONDecoder().decode([HourlyBucket].self, from: Data(json.utf8))
        XCTAssertNil(old[0].sessionsStarted)
        XCTAssertTrue(old[0].costIncomplete)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("sessionsStarted"))
        let fresh = build([ev("2026-07-29T14:00:00Z")], "2026-07-29T16:00:00Z")
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self).contains("\"sessionsStarted\":1"))
    }

    func testAModelSwitchMidSessionSplitsTheBuckets() {
        var a = session("2026-07-29T14:00:00Z", "s1", model: "sonnet-5")
        a.tokensIn = 10
        var b = session("2026-07-29T14:05:00Z", "s1", model: "opus-5")
        b.tokensIn = 20
        let buckets = build([a, b], "2026-07-29T15:00:00Z")
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.tokensIn).reduce(0, +), 30)
    }

    func testEventsFromTheFutureAreIgnored() {
        var e = ev("2026-07-30T14:00:00Z")
        e.tokensIn = 999
        XCTAssertTrue(build([e], "2026-07-29T15:00:00Z").isEmpty, "clock skew must not create future buckets")
    }

    func testAfterHoursAndWeekendNeverExceedActiveTime() {
        let buckets = build([ev("2026-07-29T02:00:00Z"), ev("2026-07-29T02:03:00Z")], "2026-07-29T12:00:00Z", zone("UTC"))
        for b in buckets {
            XCTAssertLessThanOrEqual(b.afterHoursMs, b.activeMs)
            XCTAssertLessThanOrEqual(b.weekendMs, b.activeMs)
            XCTAssertLessThan(b.localHour, 24)
            XCTAssertLessThan(b.localDow, 7)
        }
    }

    /// 18:00 UTC is 11:00 in Los Angeles (PDT) and 03:00 in Tokyo.
    func testAfterHoursUsesMemberIANAZoneNotUTC() {
        let events = [ev("2026-07-29T18:00:00Z"), ev("2026-07-29T18:02:00Z")]
        let la = build(events, "2026-07-29T20:00:00Z", zone("America/Los_Angeles"))
        XCTAssertEqual(la.count, 1)
        XCTAssertEqual(la[0].localHour, 11)
        XCTAssertEqual(la[0].afterHoursMs, 0, "11:00 PDT is inside 08:00–18:00")
        let tokyo = build(events, "2026-07-29T20:00:00Z", zone("Asia/Tokyo"))
        XCTAssertEqual(tokyo.count, 1)
        XCTAssertEqual(tokyo[0].localHour, 3)
        XCTAssertTrue(tokyo[0].afterHoursMs > 0 && tokyo[0].afterHoursMs == tokyo[0].activeMs)
    }

    /// Friday 20:00 UTC is still Friday in London, Saturday morning in Tokyo.
    func testWeekendFlagFollowsMemberLocalCalendar() {
        let events = [ev("2026-07-31T20:00:00Z"), ev("2026-07-31T20:02:00Z")]
        let london = build(events, "2026-08-01T12:00:00Z", zone("Europe/London"))
        XCTAssertEqual(london[0].localDow, 4)
        XCTAssertEqual(london[0].weekendMs, 0)
        let tokyo = build(events, "2026-08-01T12:00:00Z", zone("Asia/Tokyo"))
        XCTAssertEqual(tokyo[0].localDow, 5)
        XCTAssertGreaterThan(tokyo[0].weekendMs, 0)
    }

    func testTimeZoneNameFallsBackToUTCForJunk() {
        XCTAssertEqual(zone("Not/AZone"), TimeZone(identifier: "UTC"))
        XCTAssertEqual(zone("Asia/Tokyo").identifier, "Asia/Tokyo")
    }

    func testBucketsComeOutInAStableOrder() {
        let buckets = build([ev("2026-07-29T15:00:00Z"), ev("2026-07-29T09:00:00Z")], "2026-07-29T16:00:00Z")
        XCTAssertEqual(buckets[0].hourUtc, "2026-07-29T09")
        XCTAssertEqual(buckets[1].hourUtc, "2026-07-29T15")
    }

    func testProjectKeyKeepsAPublicBasenameAndDropsThePath() {
        XCTAssertEqual(TeamsAggregator.projectKey(workDir: "/Users/neel/code/helios-api", private: false), "helios-api")
        XCTAssertEqual(TeamsAggregator.projectKey(workDir: "/Users/neel/code/helios-api/", private: false), "helios-api")
    }

    func testProjectKeyHashesAPrivateRepoInsteadOfNamingIt() {
        let key = TeamsAggregator.projectKey(workDir: "/Users/neel/secret/acquisition-target", private: true)
        XCTAssertEqual(key.count, 8)
        XCTAssertFalse(key.contains("acquisition"))
        XCTAssertEqual(key, TeamsAggregator.projectKey(workDir: "/Users/neel/secret/acquisition-target", private: true))
    }

    func testProjectKeyNeverEmitsASeparator() {
        for input in ["/a/b/c", "C:\\work\\repo", "", "/"] {
            let key = TeamsAggregator.projectKey(workDir: input, private: false)
            XCTAssertFalse(key.contains("/"), "\(input) leaked a separator")
            XCTAssertFalse(key.contains("\\"), "\(input) leaked a separator")
        }
    }

    func testParseTimestampHandlesBothFormats() {
        XCTAssertNotNil(TeamsTime.parse("2026-07-29T14:00:00Z"))
        XCTAssertNotNil(TeamsTime.parse("2026-07-29 14:00:00"))
        XCTAssertNil(TeamsTime.parse("not a date"))
    }

    func testABucketSerialisesWithTheCamelCaseTheWorkerExpects() throws {
        var b = HourlyBucket()
        (b.hourUtc, b.provider, b.tokensIn, b.tokensReasoning) = ("2026-07-29T14", "ClaudeCode", 5, 7)
        let json = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        XCTAssertTrue(json.contains("\"hourUtc\":\"2026-07-29T14\""))
        XCTAssertTrue(json.contains("\"tokensIn\":5"))
        XCTAssertTrue(json.contains("\"tokensReasoning\":7"))
        XCTAssertFalse(json.contains("hour_utc"))
    }

    // MARK: - Swift-only checks of the port's own helpers

    func testShortHashIsTheSHA256Prefix() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        XCTAssertEqual(TeamsLabels.shortHash("abc"), "ba7816bf")
        XCTAssertEqual(SHA256.digest(Array(String(repeating: "a", count: 1000).utf8)).prefix(4).map { String(format: "%02x", $0) }.joined(),
                       "41edece4")
        // Same label agmux uploads for this path (`shasum -a 256`).
        XCTAssertEqual(TeamsAggregator.projectKey(workDir: "/Users/neel/secret/acquisition-target", private: true), "0915905c")
    }

    func testTimestampsKeepFractionsAndOffsets() {
        XCTAssertEqual(TeamsTime.parse("2026-07-29T23:30:00.250+09:00"), TeamsTime.parse("2026-07-29T14:30:00.25Z"))
        XCTAssertNil(TeamsTime.parse("2026-02-30T00:00:00Z"))
        XCTAssertNil(TeamsTime.parse("2026-07-29T14:00:00"), "RFC 3339 needs an offset")
    }
}
