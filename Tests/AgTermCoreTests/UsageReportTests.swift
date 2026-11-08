import AgTermCore
import XCTest

final class UsageReportTests: XCTestCase {
    /// A fixed zone 8 hours behind UTC, so local midnight is 08:00 UTC.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        return calendar
    }()

    /// 2026-11-08 12:00 local (20:00 UTC).
    private let now = Date(timeIntervalSince1970: 1_794_168_000)

    private func event(_ hoursAgo: Double, model: String = "claude-opus-5-5", project: String = "agterm",
                       session: String = "s1", provider: String = "ClaudeCode", tokensIn: Int = 100, tokensOut: Int = 10,
                       cost: Double = 1, incomplete: Bool = false, rowKey: String? = nil) -> UsageEvent {
        var e = UsageEvent(at: now.addingTimeInterval(-hoursAgo * 3600), provider: provider, model: model,
                           projectKey: project, sessionID: session)
        e.tokensIn = tokensIn
        e.tokensOut = tokensOut
        e.costUSD = cost
        e.costIncomplete = incomplete
        e.claudeRowKey = rowKey
        return e
    }

    func testEmptyInput() {
        let report = UsageReport.build(events: [], now: now, calendar: calendar)
        XCTAssertEqual(report.days.count, 30)
        XCTAssertTrue(report.days.allSatisfy { $0.totals == .zero })
        for period in UsagePeriod.allCases {
            XCTAssertEqual(report.summary(period).totals, .zero)
            XCTAssertTrue(report.summary(period).models.isEmpty)
            XCTAssertTrue(report.summary(period).projects.isEmpty)
        }
    }

    func testDayBucketingAcrossLocalMidnight() {
        // 11:00 and 13:00 before noon: 01:00 today and 23:00 yesterday, local time.
        let report = UsageReport.build(events: [event(11, cost: 2), event(13, cost: 3)], now: now, calendar: calendar)
        XCTAssertEqual(report.days.last?.totals.costUSD, 2)
        XCTAssertEqual(report.days[report.days.count - 2].totals.costUSD, 3)
        XCTAssertEqual(report.days.last?.start, calendar.startOfDay(for: now))
        XCTAssertEqual(report.days.first?.start, calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)))
    }

    func testPeriodTotals() {
        let events = [
            event(1, tokensIn: 100, tokensOut: 10, cost: 1),               // today
            event(13, session: "s2", tokensIn: 200, tokensOut: 20, cost: 2), // yesterday
            event(24 * 8, session: "s3", cost: 4, incomplete: true),       // 8 days ago
            event(24 * 40, session: "s4", cost: 100),                      // outside 30 days
        ]
        let report = UsageReport.build(events: events, now: now, calendar: calendar)
        XCTAssertEqual(report.summary(.today).totals.costUSD, 1)
        XCTAssertEqual(report.summary(.today).totals.sessions, 1)
        XCTAssertEqual(report.summary(.today).totals.tokens, 110)
        XCTAssertEqual(report.summary(.week).totals.costUSD, 3)
        XCTAssertEqual(report.summary(.week).totals.sessions, 2)
        XCTAssertFalse(report.summary(.week).totals.costIncomplete)
        XCTAssertEqual(report.summary(.month).totals.costUSD, 7)
        XCTAssertEqual(report.summary(.month).totals.sessions, 3)
        XCTAssertTrue(report.summary(.month).totals.costIncomplete)
    }

    func testFutureEventsAreIgnored() {
        let report = UsageReport.build(events: [event(-2, cost: 9)], now: now, calendar: calendar)
        XCTAssertEqual(report.summary(.today).totals, .zero)
    }

    func testModelAndProjectRanking() {
        let events = [
            event(1, model: "gpt-5.5-codex", project: "site", provider: "Codex", cost: 1),
            event(2, model: "claude-opus-5-5", project: "agterm", cost: 5),
            event(3, model: "claude-haiku-5-5", project: "agterm", tokensIn: 5000, cost: 1),
            event(4, model: "claude-opus-5-5", project: "site", cost: 1),
        ]
        let summary = UsageReport.build(events: events, now: now, calendar: calendar).summary(.today)
        XCTAssertEqual(summary.models.map(\.name), ["claude-opus-5-5", "claude-haiku-5-5", "gpt-5.5-codex"])
        XCTAssertEqual(summary.models.first?.totals.costUSD, 6)
        XCTAssertEqual(summary.projects.map(\.name), ["agterm", "site"])
        XCTAssertEqual(summary.projects.first?.totals.costUSD, 6)
    }

    func testClaudeDuplicatesCountOnce() {
        let events = [event(1, cost: 2, rowKey: "m1:r1"), event(1, session: "fork", cost: 2, rowKey: "m1:r1")]
        let report = UsageReport.build(events: events, now: now, calendar: calendar)
        XCTAssertEqual(report.summary(.today).totals.costUSD, 2)
    }

    func testSubagentsAreNotSessions() {
        var child = event(1, session: "child")
        child.subagent = true
        let report = UsageReport.build(events: [event(1), child], now: now, calendar: calendar)
        XCTAssertEqual(report.summary(.today).totals.sessions, 1)
        XCTAssertEqual(report.summary(.today).totals.costUSD, 2)
    }
}
