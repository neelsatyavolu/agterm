import XCTest
@testable import AgTermCore

/// Replies shaped like teams-service's `routes/dashboard.ts` and `routes/teams.ts` (field names
/// from `aggregate.ts` `Totals`, `DayPoint`, `MixSlice`, `ProjectRow` and `logins.ts` `LoginRow`).
final class TeamDashboardTests: XCTestCase {
    static let totals = """
    {"tokensIn":120000,"tokensOut":30000,"tokensCacheRead":800000,"tokensCacheWrite":50000,"tokensReasoning":4000,
     "tokens":1000000,"cacheHitRate":0.87,"costUsd":42.5,"costIncomplete":false,"activeHours":12.25,
     "afterHoursShare":0.1,"weekendShare":0.05,"sessions":30,"sessionsStarted":9,"sessionsStartedIncomplete":false,
     "turns":400,"toolCalls":900,"peakConcurrent":3,"daysWithData":5,
     "toolMix":{"bash":300,"edit":200,"read":250,"search":100,"web":10,"agent":20,"mcp":5,"other":15},
     "toolErrors":12,"toolsMeasured":600,"toolErrorRate":0.02,"filesChanged":40,"linesAdded":1200,"linesRemoved":300,
     "approvalRequests":0,"approvalWaitHours":0,"meanApprovalWaitSec":null}
    """

    static let overview = """
    {"ok":true,"data":{
      "range":"30d","from":"2026-10-10","to":"2026-11-08","scope":"team","scopeLabel":null,"role":"owner",
      "totals":\(totals),
      "deltas":{"tokens":0.25,"costUsd":-0.1,"activeHours":null,"sessions":0,"sessionsStarted":null},
      "daily":[
        {"date":"2026-11-07","label":"11/7","full":"Sat, Nov 7","tokens":600000,"activeHours":7.5,"sessions":20,
         "sessionsStarted":5,"sessionsStartedIncomplete":false,"peakConcurrent":3,"weekend":true,"hasData":true},
        {"date":"2026-11-08","label":"11/8","full":"Sun, Nov 8","tokens":400000,"activeHours":4.75,"sessions":10,
         "sessionsStarted":4,"sessionsStartedIncomplete":false,"peakConcurrent":2,"weekend":true,"hasData":true}],
      "heatmap":[[0,1],[2,3]],
      "providerMix":[{"key":"claude","tokens":700000,"share":0.7,"activeMs":30000000,"timeShare":0.68},
                     {"key":"codex","tokens":300000,"share":0.3,"activeMs":14100000,"timeShare":0.32}],
      "modelMix":[{"key":"claude-opus-4-5","tokens":700000,"share":0.7,"activeMs":30000000,"timeShare":0.68}],
      "projects":[{"projectKey":"agterm","activeHours":8,"tokens":600000,"sessions":20,"sessionsStarted":6,
                   "sessionsStartedIncomplete":false}],
      "flags":{"afterHoursShare":0.1,"afterHoursSharePrev":0.05,"weekendShare":0.05,"idleDays":2},
      "budget":{"costIncomplete":false,"month":"2026-11","monthlyUsd":500,"spendUsd":120,"usedShare":0.24,
                "projectedUsd":450,"projectedShare":0.9,"daysElapsed":8,"daysInMonth":30,"onTrackToExceed":false,
                "thresholds":[0.8,1],"hasWebhook":false},
      "canManageBudget":true,"canViewAudit":true,
      "members":[
        {"userId":"u1","displayName":"Ada","handle":"ada","avatarColor":"#60a5fa","avatarUrl":null,"role":"owner",
         "lastUploadAt":"2026-11-08 09:00:00","timezone":"Europe/London","neverSynced":false,
         "joinedAt":"2026-01-01","totals":\(totals)},
        {"userId":"u2","displayName":"Grace","handle":null,"avatarColor":"#fbbf24","role":"employee",
         "lastUploadAt":null,"timezone":null,"neverSynced":true,"joinedAt":"2026-02-01","totals":{}}],
      "memberCount":2,"teamMemberCount":2,"lastUploadAt":"2026-11-08 09:00:00"}}
    """

    static let detail = """
    {"ok":true,"data":{
      "range":"7d","role":"owner","isSelf":false,
      "member":{"user_id":"u1","display_name":"Ada","handle":"ada","avatar_color":"#60a5fa","role":"owner",
                "joined_at":"2026-01-01","last_upload_at":"2026-11-08T09:00:00Z","timezone":"Europe/London"},
      "totals":\(totals),"daily":[],"heatmap":[],"providerMix":[],"modelMix":[],"projects":[],
      "flags":{"afterHoursShare":0,"afterHoursSharePrev":0,"weekendShare":0,"idleDays":0},
      "neverSynced":false,
      "logins":{"reported":true,"rows":[
        {"provider":"claude","identityHash":"aaaa","name":"ada@example.com","nameSource":"email","tokens":700,
         "costUsd":1.5,"costIncomplete":false,"activeHours":2,"share":0.7},
        {"provider":"codex","identityHash":"bbbb","name":"Team Codex Pro","nameSource":"team","tokens":200,
         "costUsd":0.4,"costIncomplete":false,"activeHours":1,"share":0.2},
        {"provider":"claude","identityHash":null,"name":"Not attributed","nameSource":"none","tokens":100,
         "costUsd":0.1,"costIncomplete":true,"activeHours":0,"share":null}]}}}
    """

    func data(_ s: String) -> Data { Data(s.utf8) }

    func testDecodesOverview() throws {
        let o: TeamDashboard.Overview = try TeamDashboard.unwrap(status: 200, body: data(Self.overview))
        XCTAssertEqual(o.scope, .team)
        XCTAssertEqual(o.role, .owner)
        XCTAssertEqual(o.totals.tokens, 1_000_000)
        XCTAssertEqual(o.totals.costUsd, 42.5)
        XCTAssertEqual(o.totals.toolMix["bash"], 300)
        XCTAssertEqual(o.totals.toolErrorRate, 0.02)
        XCTAssertEqual(o.deltas.tokens, 0.25)
        XCTAssertNil(o.deltas.activeHours)
        XCTAssertEqual(o.daily.map(\.label), ["11/7", "11/8"])
        XCTAssertEqual(o.daily[0].activeHours, 7.5)
        XCTAssertEqual(o.providerMix.map(\.key), ["claude", "codex"])
        XCTAssertEqual(o.projects.first?.projectKey, "agterm")
        XCTAssertEqual(o.budget?.monthlyUsd, 500)
        XCTAssertEqual(o.members.map(\.displayName), ["Ada", "Grace"])
        XCTAssertTrue(o.members[1].neverSynced)
        XCTAssertEqual(o.members[1].totals.tokens, 0, "an empty totals object decodes to zeros")
        XCTAssertEqual(o.memberCount, 2)
        XCTAssertEqual(o.flags.idleDays, 2)
        XCTAssertEqual(o.state, .full)
    }

    func testOverviewToleratesMissingAndWrongFields() throws {
        let o: TeamDashboard.Overview = try TeamDashboard.unwrap(status: 200, body: data(
            #"{"ok":true,"data":{"scope":"galaxy","role":"admiral","totals":{"tokens":"many"},"members":[{"userId":"u"}],"budget":null}}"#))
        XCTAssertEqual(o.scope, .team)
        XCTAssertEqual(o.role, .employee)
        XCTAssertEqual(o.totals.tokens, 0)
        XCTAssertEqual(o.range, .month)
        XCTAssertNil(o.budget)
        XCTAssertEqual(o.members.first?.displayName, "Member")
        XCTAssertEqual(o.state, .waiting)
    }

    func testSelfScopeAndPartialScope() throws {
        let me: TeamDashboard.Overview = try TeamDashboard.unwrap(status: 200, body: data(
            #"{"ok":true,"data":{"scope":"self","role":"employee","totals":{"daysWithData":3},"members":[]}}"#))
        XCTAssertEqual(me.state, .selfOnly)
        let partial: TeamDashboard.Overview = try TeamDashboard.unwrap(status: 200, body: data(
            #"{"ok":true,"data":{"scope":"partial","scopeLabel":"Platform","role":"manager","memberCount":3,"teamMemberCount":9,"totals":{"daysWithData":1}}}"#))
        XCTAssertEqual(partial.scope, .partial)
        XCTAssertEqual(partial.peopleLine, "3 people of 9 · Platform")
    }

    func testDecodesMemberDetailWithLogins() throws {
        let d: TeamDashboard.MemberDetail = try TeamDashboard.unwrap(status: 200, body: data(Self.detail))
        XCTAssertEqual(d.member.displayName, "Ada")
        XCTAssertEqual(d.member.role, .owner)
        XCTAssertEqual(d.logins?.reported, true)
        XCTAssertEqual(d.logins?.rows.map(\.name), ["ada@example.com", "Team Codex Pro", "Not attributed"])
        XCTAssertEqual(d.logins?.rows[1].provider, "codex")
        XCTAssertNil(d.logins?.rows[2].identityHash)
        XCTAssertNil(d.logins?.rows[2].share)
        XCTAssertEqual(d.totals.linesAdded, 1200)
    }

    func testOlderServerHasNoLogins() throws {
        let d: TeamDashboard.MemberDetail = try TeamDashboard.unwrap(status: 200, body: data(
            #"{"ok":true,"data":{"member":{"user_id":"u1","display_name":"Ada"},"totals":{}}}"#))
        XCTAssertNil(d.logins)
    }

    func testDecodesTeamList() throws {
        let list: TeamDashboard.TeamList = try TeamDashboard.unwrap(status: 200, body: data(
            #"{"ok":true,"data":{"teams":[{"id":"t1","slug":"nenu","name":"Nenu","role":"owner","member_count":4,"last_upload_at":null,"staffPreview":false},{"id":"t2","slug":"peek","name":"Peek","role":"manager","member_count":40,"staffPreview":true},{"slug":"broken"}],"features":{}}}"#))
        XCTAssertEqual(list.teams.map(\.id), ["t1"], "staff previews and rows without an id are left out")
        XCTAssertEqual(list.teams[0].memberCount, 4)
        XCTAssertTrue(list.teams[0].role.isAdmin)
    }

    func testFailuresByStatus() {
        func failure(_ status: Int, _ body: String = "") -> TeamDashboard.Failure? {
            do { let _: TeamDashboard.TeamList = try TeamDashboard.unwrap(status: status, body: data(body)); return nil }
            catch { return error as? TeamDashboard.Failure }
        }
        XCTAssertEqual(failure(401), .signedOut)
        XCTAssertEqual(failure(404, #"{"ok":false,"error":"That team doesn't exist.","code":"not_found"}"#), .notMember)
        XCTAssertEqual(failure(403, #"{"ok":false,"error":"Your role (employee) can't do that."}"#),
                       .refused("Your role (employee) can't do that."))
        XCTAssertEqual(failure(503), .unavailable)
        XCTAssertEqual(failure(200, "<html>"), .unexpected)
        XCTAssertEqual(failure(200, #"{"ok":false,"error":"nope"}"#), .refused("nope"))
    }

    func testCacheRoundTrips() throws {
        let o: TeamDashboard.Overview = try TeamDashboard.unwrap(status: 200, body: data(Self.overview))
        var cache = TeamDashboard.Cache()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        cache.store(o, team: "t1", range: .month, at: at)
        let copy = try JSONDecoder().decode(TeamDashboard.Cache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(copy.overview(team: "t1", range: .month)?.value, o)
        XCTAssertEqual(copy.overview(team: "t1", range: .month)?.fetchedAt, at)
        XCTAssertNil(copy.overview(team: "t1", range: .week))
    }

    func testFormatting() {
        XCTAssertEqual(TeamDashboard.tokens(0), "0")
        XCTAssertEqual(TeamDashboard.tokens(950), "950")
        XCTAssertEqual(TeamDashboard.tokens(12_400), "12.4k")
        XCTAssertEqual(TeamDashboard.tokens(1_000_000), "1.0M")
        XCTAssertEqual(TeamDashboard.tokens(2_500_000_000), "2.5B")
        XCTAssertEqual(TeamDashboard.money(0), "$0")
        XCTAssertEqual(TeamDashboard.money(4.256), "$4.26")
        XCTAssertEqual(TeamDashboard.money(1234), "$1,234")
        XCTAssertEqual(TeamDashboard.percent(0.874), "87%")
        XCTAssertEqual(TeamDashboard.hours(12.34), "12.3h")
        XCTAssertEqual(TeamDashboard.delta(0.25), "+25%")
        XCTAssertEqual(TeamDashboard.delta(-0.1), "−10%")
        XCTAssertNil(TeamDashboard.delta(nil))
    }

    func testParsesServerTimestamps() {
        let sqlite = TeamDashboard.date("2026-11-08 09:00:00")
        let iso = TeamDashboard.date("2026-11-08T09:00:00Z")
        XCTAssertNotNil(sqlite)
        XCTAssertEqual(sqlite, iso)
        XCTAssertNil(TeamDashboard.date("yesterday"))
    }
}
