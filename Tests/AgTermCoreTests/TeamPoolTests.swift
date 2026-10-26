import XCTest
@testable import AgTermCore

final class TeamPoolTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let team = TeamPool.Team(id: "t1", name: "Nenu")
    let credentials: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["access_token": "secret-a", "refresh_token": "secret-r",
                                                                         "id_token": "secret-i", "account_id": "acct"]]

    func body(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func ok(_ data: Any) -> Data { body(["ok": true, "data": data]) }

    func testTeamsSkipStaffPreviewsAndRejectBadReplies() throws {
        let teams = try TeamPool.teams(status: 200, body: ok(["teams": [["id": "t1", "name": "Nenu", "role": "employee"],
                                                                         ["id": "t2", "name": "Peek", "staffPreview": true]]]))
        XCTAssertEqual(teams, [team])
        XCTAssertThrowsError(try TeamPool.teams(status: 200, body: body(["ok": false, "error": "secret-token"]))) { error in
            XCTAssertFalse((error as? TeamPool.Failure)?.message.contains("secret") ?? true)
        }
        XCTAssertThrowsError(try TeamPool.teams(status: 401, body: Data())) { error in
            XCTAssertEqual((error as? TeamPool.Failure)?.retryable, false)
        }
    }

    func testAccountsKeepCodexOnlyAndReadStatus() throws {
        let rows: [[String: Any]] = [
            ["id": "a", "provider": "codex", "label": "Work", "enabled": true, "remainingPercent": 70, "plan": "Pro 20x",
             "healthReportedAt": 1_789_999_900],
            ["id": "b", "provider": "grok", "label": "Grok", "enabled": true],
            ["id": "c", "provider": "codex", "label": "Busy", "enabled": true, "leasedUntil": 1_790_000_200,
             "inUse": ["self": false, "by": "Alex", "kind": "session"]],
            ["id": "d", "provider": "codex", "label": "Out", "enabled": true, "remainingPercent": 0, "blockedUntil": 1_790_003_600],
            ["id": "e", "provider": "codex", "label": "Reset", "enabled": true, "lastRemainingPercent": 10, "blockedUntil": 1_789_000_000],
        ]
        let accounts = try XCTUnwrap(TeamPool.accounts(status: 200, body: ok(["accounts": rows]), team: team))
        XCTAssertEqual(accounts.map(\.id), ["a", "c", "d", "e"])
        XCTAssertTrue(accounts[0].borrowable(now))
        XCTAssertEqual(accounts[0].plan, "Pro 20x")
        XCTAssertTrue(accounts[1].leased(now))
        XCTAssertEqual(accounts[1].inUseBy, "Alex")
        XCTAssertFalse(accounts[1].borrowable(now))
        XCTAssertTrue(accounts[2].exhausted(now))
        // A reset that already passed means the old reading says nothing.
        XCTAssertFalse(accounts[3].exhausted(now))
        XCTAssertNil(accounts[3].shownRemaining(now))
    }

    func testPoolAbsentOnlyWhenTheServerSaysSo() throws {
        XCTAssertNil(try TeamPool.accounts(status: 404, body: Data(), team: team))
        XCTAssertNil(try TeamPool.accounts(status: 503, body: body(["ok": false, "code": "provider_accounts_not_configured"]), team: team))
        XCTAssertThrowsError(try TeamPool.accounts(status: 503, body: body(["ok": false, "code": "provider_accounts_unavailable"]), team: team)) { error in
            XCTAssertEqual((error as? TeamPool.Failure)?.retryable, true)
        }
    }

    func testLeaseParsing() throws {
        let reply: [String: Any] = ["leaseId": "pal_1", "expiresAt": 1_790_000_300, "credentials": credentials,
                                    "account": ["id": "pac_1", "provider": "codex", "label": "Work", "enabled": true, "remainingPercent": 55]]
        let lease = try XCTUnwrap(TeamPool.lease(status: 200, body: ok(reply), team: "t1", provider: .codex, now: now))
        XCTAssertEqual(lease.accountID, "pac_1")
        XCTAssertEqual(lease.remainingPercent, 55)
        let saved = try JSONSerialization.jsonObject(with: lease.credentials) as? [String: Any]
        XCTAssertEqual((saved?["tokens"] as? [String: Any])?["refresh_token"] as? String, "secret-r")
        // No free account is an answer, not an error; other conflicts are errors.
        XCTAssertNil(try TeamPool.lease(status: 409, body: body(["ok": false, "code": "no_provider_account_available"]), team: "t1", provider: .codex, now: now))
        XCTAssertThrowsError(try TeamPool.lease(status: 409, body: body(["ok": false, "code": "conflict"]), team: "t1", provider: .codex, now: now))
        // A check must return the very account asked for, and says when a teammate has it.
        XCTAssertThrowsError(try TeamPool.lease(status: 200, body: ok(reply), team: "t1", provider: .codex, account: "pac_2", now: now))
        XCTAssertThrowsError(try TeamPool.lease(status: 409, body: Data(), team: "t1", provider: .codex, account: "pac_1", now: now)) { error in
            XCTAssertEqual(error as? TeamPool.Failure, TeamPool.inUse)
        }
        var expired = reply
        expired["expiresAt"] = 1_789_999_999
        XCTAssertThrowsError(try TeamPool.lease(status: 200, body: ok(expired), team: "t1", provider: .codex, now: now))
        var apiKey = reply
        apiKey["credentials"] = ["auth_mode": "apikey", "OPENAI_API_KEY": "sk-secret"]
        XCTAssertThrowsError(try TeamPool.lease(status: 200, body: ok(apiKey), team: "t1", provider: .codex, now: now))
    }

    func testRenew() throws {
        XCTAssertEqual(try TeamPool.renewed(status: 200, body: ok(["leaseId": "pal_1", "expiresAt": 1_790_000_300]), leaseID: "pal_1", now: now),
                       Date(timeIntervalSince1970: 1_790_000_300))
        XCTAssertThrowsError(try TeamPool.renewed(status: 200, body: ok(["leaseId": "pal_2", "expiresAt": 1_790_000_300]), leaseID: "pal_1", now: now))
        let body = try XCTUnwrap(TeamPool.renewBody(credentials: self.body(credentials), health: TeamPool.Health(remainingPercent: 40, blockedUntil: 0)))
        XCTAssertEqual(body["remainingPercent"] as? Double, 40)
        XCTAssertEqual(body["blockedUntil"] as? Int, 0)
        XCTAssertNotNil(body["credentials"])
        // A credentials-only renewal leaves the last measurement alone.
        let quiet = try XCTUnwrap(TeamPool.renewBody(credentials: self.body(credentials), health: nil))
        XCTAssertNil(quiet["remainingPercent"])
        XCTAssertNil(quiet["blockedUntil"])
        XCTAssertNil(TeamPool.renewBody(credentials: Data("{}".utf8), health: nil))
    }

    func testHealthFromUsage() {
        let reset = now.addingTimeInterval(3600)
        let healthy = UsageReading(windows: [UsageWindow(name: "Weekly", usedPercent: 30, resetsAt: reset)], checkedAt: now)
        XCTAssertEqual(TeamPool.Health(healthy, now: now), TeamPool.Health(remainingPercent: 70, blockedUntil: 0))
        let out = UsageReading(windows: [UsageWindow(name: "5-hour", usedPercent: 100, resetsAt: reset)], checkedAt: now)
        XCTAssertEqual(TeamPool.Health(out, now: now), TeamPool.Health(remainingPercent: 0, blockedUntil: Int(reset.timeIntervalSince1970)))
        let credits = UsageReading(windows: [UsageWindow(name: "5-hour", usedPercent: 100, resetsAt: reset)], hasCredits: true, checkedAt: now)
        XCTAssertEqual(TeamPool.Health(credits, now: now), TeamPool.Health(remainingPercent: nil, blockedUntil: 0))
        XCTAssertNil(TeamPool.Health(UsageReading(windows: [], checkedAt: now), now: now))
        XCTAssertNil(TeamPool.Health(nil, now: now))
        // Running out with no known reset blocks it for an hour, not for good.
        XCTAssertEqual(TeamPool.Health.exhausted(until: nil, now: now), TeamPool.Health(remainingPercent: 0, blockedUntil: 1_790_003_600))
        XCTAssertEqual(TeamPool.Health.exhausted(until: reset, now: now).blockedUntil, Int(reset.timeIntervalSince1970))
    }

    func testLocalIDs() {
        XCTAssertEqual(TeamPool.localID(leaseID: "pal_1/../x"), "team-pal_1x")
        XCTAssertTrue(TeamPool.isLocalID("team-pal_1"))
        XCTAssertFalse(TeamPool.isLocalID("team-"))
        XCTAssertFalse(TeamPool.isLocalID("native"))
    }

    /// owner.pid names the agent only if that process started before the file was written; a
    /// process that started later got the pid after the agent exited.
    func testOwnerMustHaveStartedBeforeThePidFileWasWritten() {
        let written = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(TeamPool.isOwner(processStartedAt: written.addingTimeInterval(-30), pidFileWrittenAt: written))
        XCTAssertTrue(TeamPool.isOwner(processStartedAt: written.addingTimeInterval(1), pidFileWrittenAt: written),
                      "clock granularity is allowed for")
        XCTAssertFalse(TeamPool.isOwner(processStartedAt: written.addingTimeInterval(TeamPool.ownerClockSlack + 0.5), pidFileWrittenAt: written))
        XCTAssertFalse(TeamPool.isOwner(processStartedAt: written.addingTimeInterval(3_600), pidFileWrittenAt: written))
        XCTAssertFalse(TeamPool.isOwner(processStartedAt: nil, pidFileWrittenAt: written), "no such process")
        XCTAssertFalse(TeamPool.isOwner(processStartedAt: written, pidFileWrittenAt: nil), "no pid file")
    }

    func testDetachingKeepsLoansWhoseAgentRunsInAKeptTab() {
        let loans = [
            TeamPool.HeldLoan(id: "kept", owner: 10, tabID: "A"),
            TeamPool.HeldLoan(id: "exited", owner: 11, tabID: "A"),
            TeamPool.HeldLoan(id: "fallback", owner: 12, tabID: "B"),
            TeamPool.HeldLoan(id: "not-started", owner: nil, tabID: "A"),
        ]
        let alive: (Int32) -> Bool = { $0 != 11 }
        XCTAssertEqual(TeamPool.loansToKeep(loans, keptTabs: ["A"], detaching: true, alive: alive), ["kept"])
        XCTAssertEqual(TeamPool.loansToKeep(loans, keptTabs: ["A"], detaching: false, alive: alive), [],
                       "ending every session returns every loan")
    }

    func testLaunchKeepsLeftoverLoansWhoseAgentStillRuns() {
        let loans = [
            TeamPool.HeldLoan(id: "running", owner: 10, tabID: nil),
            TeamPool.HeldLoan(id: "gone", owner: 11, tabID: nil),
            TeamPool.HeldLoan(id: "never-started", owner: nil, tabID: nil),
        ]
        XCTAssertEqual(TeamPool.leftoverLoansToKeep(loans, alive: { $0 == 10 }), ["running"])
    }
}
