import XCTest
@testable import AgTermCore

/// Renaming, pausing and removing pooled logins: `PATCH`/`DELETE /api/teams/:id/provider-accounts/:account`
/// in teams-service's `routes/provider-accounts.ts`.
final class TeamPoolAdminTests: XCTestCase {
    let team = TeamPool.Team(id: "t1", name: "Nenu", canAdd: true)

    func body(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func ok(_ data: Any) -> Data { body(["ok": true, "data": data]) }

    func testReadsWhetherYouCanManageALogin() throws {
        let rows: [[String: Any]] = [
            ["id": "a", "provider": "codex", "label": "Mine", "enabled": true, "canManage": true, "createdBy": "u1"],
            ["id": "b", "provider": "grok", "label": "Theirs", "enabled": false],
        ]
        let accounts = try XCTUnwrap(TeamPool.accounts(status: 200, body: ok(["accounts": rows]), team: team))
        XCTAssertEqual(accounts.map(\.canManage), [true, false])
        XCTAssertEqual(accounts.map(\.enabled), [true, false])
    }

    func testRenameBodyTrimsAndRejectsBadNames() {
        XCTAssertEqual(TeamPool.renameBody("  Work Pro  ")?["label"] as? String, "Work Pro")
        XCTAssertNil(TeamPool.renameBody("   "))
        XCTAssertNil(TeamPool.renameBody(String(repeating: "x", count: 121)))
        XCTAssertNil(TeamPool.renameBody("bad\u{7}name"))
    }

    func testPauseBody() {
        XCTAssertEqual(TeamPool.pauseBody(paused: true)["enabled"] as? Bool, false)
        XCTAssertEqual(TeamPool.pauseBody(paused: false)["enabled"] as? Bool, true)
    }

    func testChangedReply() throws {
        let row: [String: Any] = ["id": "a", "provider": "codex", "label": "Renamed", "enabled": false, "canManage": true]
        let account = try TeamPool.changed(status: 200, body: ok(["account": row]), team: team)
        XCTAssertEqual(account.label, "Renamed")
        XCTAssertFalse(account.enabled)
        XCTAssertThrowsError(try TeamPool.changed(status: 404, body: Data(), team: team)) { error in
            XCTAssertEqual((error as? TeamPool.Failure)?.message, TeamPool.notManageable.message)
        }
        XCTAssertThrowsError(try TeamPool.changed(status: 403, body: Data(), team: team)) { error in
            XCTAssertEqual((error as? TeamPool.Failure)?.message, TeamPool.notManageable.message)
        }
        XCTAssertThrowsError(try TeamPool.changed(status: 200, body: ok([:]), team: team))
    }

    func testRemovedReply() throws {
        XCTAssertNoThrow(try TeamPool.removed(status: 200, body: ok(["deleted": true])))
        XCTAssertThrowsError(try TeamPool.removed(status: 200, body: ok(["deleted": false])))
        XCTAssertThrowsError(try TeamPool.removed(status: 404, body: Data()))
        XCTAssertThrowsError(try TeamPool.removed(status: 503, body: Data())) { error in
            XCTAssertEqual((error as? TeamPool.Failure)?.retryable, true)
        }
    }
}
