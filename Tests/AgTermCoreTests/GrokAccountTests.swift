import XCTest
@testable import AgTermCore

final class GrokAccountTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_600_000)
    let team = TeamPool.Team(id: "t1", name: "Nenu", canAdd: true)
    let auth: [String: Any] = [
        "https://auth.x.ai::client": ["key": "secret-access", "refresh_token": "secret-refresh", "user_id": "u1", "principal_id": "u1",
                                      "email": "me@example.com", "expires_at": "2026-10-26T20:32:45.335736Z"],
    ]

    func body(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func ok(_ data: Any) -> Data { body(["ok": true, "data": data]) }

    /// A real GetGrokCreditsConfig reply (36% of a week used, Oct 20–27 2026) plus its trailers.
    var billingReply: Data {
        let frame = "00000000720a700d00001042220b08d0a6dfd60610808682522a0b08d09b84d70610808682523a070802150000a0413a07080915000010413a0708"
            + "01150000a0403a070804150000803f3a070808150000803f421c0802120b08d0a6dfd60610808682521a0b08d09b84d7061080868252580162006801"
        let trailer = "grpc-status:0\r\n"
        return hex(frame) + Data([0x80, 0, 0, 0, UInt8(trailer.utf8.count)]) + Data(trailer.utf8)
    }

    func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map { i in
            UInt8(text[text.index(text.startIndex, offsetBy: i)...].prefix(2), radix: 16)!
        })
    }

    func testBillingReplyReadsPercentAndPeriod() throws {
        let snapshot = try XCTUnwrap(GrokBilling.parse(billingReply, now: now))
        XCTAssertEqual(snapshot.usedPercent, 36)
        XCTAssertEqual(snapshot.periodStart, Date(timeIntervalSince1970: 1_792_529_232))
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 1_793_134_032))
        let reading = GrokBilling.reading(snapshot, plan: "SuperGrok Plus", email: "me@example.com", now: now)
        XCTAssertEqual(reading.windows, [UsageWindow(name: "Weekly", usedPercent: 36, resetsAt: snapshot.resetsAt)])
        XCTAssertEqual(reading.remainingPercent, 64)
        XCTAssertNil(reading.exhaustedUntil(now))
        XCTAssertEqual(reading.plan, "SuperGrok Plus")
    }

    func testBillingReplyEdgeCases() throws {
        // A new period with nothing used has no float: 0% used. Field 1 { 5 { 1: end } 8 { 1: 2 } }.
        let end = hex("08d09b84d706")
        let period = Data([0x2A, UInt8(end.count)]) + end
        let kind = Data([0x42, 0x02, 0x08, 0x02])
        let message = Data([0x0A, UInt8(period.count + kind.count)]) + period + kind
        let framed = Data([0, 0, 0, 0, UInt8(message.count)]) + message
        XCTAssertEqual(try XCTUnwrap(GrokBilling.parse(framed, now: now)).usedPercent, 0)
        // At 0% the reply leaves the percent field out but still has the rest (other floats too).
        var zero = [UInt8](billingReply)
        zero.removeSubrange(7..<12)
        zero[4] -= 5
        zero[6] -= 5
        let fresh = try XCTUnwrap(GrokBilling.parse(Data(zero), now: now))
        XCTAssertEqual(fresh.usedPercent, 0)
        XCTAssertEqual(fresh.resetsAt, Date(timeIntervalSince1970: 1_793_134_032))
        // Over the limit reads as used up until the reset.
        var full = [UInt8](billingReply)
        full.replaceSubrange(8..<12, with: [0x00, 0x00, 0xC8, 0x42])
        let out = try XCTUnwrap(GrokBilling.parse(Data(full), now: now))
        XCTAssertEqual(out.usedPercent, 100)
        XCTAssertEqual(GrokBilling.reading(out, plan: nil, email: nil, now: now).exhaustedUntil(now), out.resetsAt)
        // Garbage and empty replies are no reading at all.
        XCTAssertNil(GrokBilling.parse(Data(), now: now))
        XCTAssertNil(GrokBilling.parse(Data([0, 0, 0, 9, 9]), now: now))
    }

    func testPlanComesFromTheNewestLoggedTier() {
        let log = """
            {"ts":"2026-10-25T16:28:30.110Z","msg":"billing: fetched credits config","ctx":{"subscriptionTier":"SuperGrok"}}
            {"ts":"2026-10-25T16:29:00.000Z","msg":"startup timing","ctx":{}}
            {"ts":"2026-10-25T16:33:30.215Z","msg":"billing: fetched credits config","ctx":{"subscriptionTier":"SuperGrok Heavy"}}
            {"ts":"2026-10-25T16:33:31.000Z","msg":"cut off mid-line","ctx":{"subscriptionTier":
            """
        XCTAssertEqual(GrokBilling.plan(logTail: log), "SuperGrok Heavy")
        XCTAssertNil(GrokBilling.plan(logTail: "{\"msg\":\"nothing\"}"))
    }

    func testLoginPrefersTheGrokSignIn() throws {
        var json = auth
        json["https://accounts.x.ai/sign-in"] = ["key": "legacy", "user_id": "u1"]
        json["other"] = ["key": "other"]
        let login = try XCTUnwrap(GrokAuth.login(json))
        XCTAssertEqual(login.token, "secret-access")
        XCTAssertEqual(login.email, "me@example.com")
        XCTAssertEqual(login.expiresAt, Date(timeIntervalSince1970: 1_793_046_765))
        XCTAssertEqual(GrokAuth.login(["https://accounts.x.ai/sign-in": ["key": "legacy"]])?.token, "legacy")
        XCTAssertNil(GrokAuth.login(["https://auth.x.ai::client": ["key": ""]]))
        XCTAssertNil(GrokAuth.login([:]))
    }

    func testOnlyOneUsersGrokSignInsCanBeShared() {
        XCTAssertTrue(GrokAuth.shareable(auth))
        XCTAssertTrue(TeamPool.validCredentials(auth, provider: .grok))
        XCTAssertFalse(TeamPool.validCredentials(auth, provider: .codex))
        XCTAssertFalse(TeamPool.validCredentials(auth, provider: .claude))
        var sameUser = auth
        sameUser["https://accounts.x.ai/sign-in"] = ["key": "x", "refresh_token": "r", "principal_id": "u1"]
        XCTAssertTrue(GrokAuth.shareable(sameUser))
        var otherScope = auth
        otherScope["https://example.com"] = ["key": "x", "refresh_token": "r", "user_id": "u1"]
        XCTAssertFalse(GrokAuth.shareable(otherScope))
        var twoUsers = auth
        twoUsers["https://accounts.x.ai/sign-in"] = ["key": "x", "refresh_token": "r", "user_id": "u2"]
        XCTAssertFalse(GrokAuth.shareable(twoUsers))
        XCTAssertFalse(GrokAuth.shareable(["https://auth.x.ai::c": ["key": "x", "refresh_token": "r", "user_id": "u1", "principal_id": "u2"]]))
        XCTAssertFalse(GrokAuth.shareable(["https://auth.x.ai::c": ["key": "x", "refresh_token": "r"]]))
        XCTAssertFalse(GrokAuth.shareable(["https://auth.x.ai::c": ["key": "", "refresh_token": "r", "user_id": "u1"]]))
        // Without a refresh token it would stop working within hours.
        XCTAssertFalse(GrokAuth.shareable(["https://auth.x.ai::c": ["key": "x", "user_id": "u1"]]))
        XCTAssertFalse(GrokAuth.shareable([:]))
    }

    func testTeamPoolLendsGrok() throws {
        let rows: [[String: Any]] = [["id": "g", "provider": "grok", "label": "Grok", "enabled": true]]
        XCTAssertEqual(try TeamPool.accounts(status: 200, body: ok(["accounts": rows]), team: team)?.map(\.provider), [.grok])
        let reply: [String: Any] = ["leaseId": "pal_1", "expiresAt": 1_792_600_300, "credentials": auth,
                                    "account": ["id": "g", "provider": "grok", "label": "Grok", "enabled": true]]
        let lease = try XCTUnwrap(TeamPool.lease(status: 200, body: ok(reply), team: "t1", provider: .grok, now: now))
        XCTAssertEqual(lease.provider, .grok)
        // A Codex request never takes a Grok account, nor the other way round.
        XCTAssertThrowsError(try TeamPool.lease(status: 200, body: ok(reply), team: "t1", provider: .codex, now: now))
        let renew = try XCTUnwrap(TeamPool.renewBody(credentials: lease.credentials, provider: .grok, health: nil))
        XCTAssertEqual(((renew["credentials"] as? [String: Any])?["https://auth.x.ai::client"] as? [String: Any])?["refresh_token"] as? String,
                       "secret-refresh")
        XCTAssertNil(TeamPool.renewBody(credentials: lease.credentials, provider: .codex, health: nil))
    }

    func testOwnersAndManagersCanAdd() throws {
        let teams = try TeamPool.teams(status: 200, body: ok(["teams": [["id": "a", "name": "A", "role": "owner"],
                                                                         ["id": "b", "name": "B", "role": "manager"],
                                                                         ["id": "c", "name": "C", "role": "employee"]]]))
        XCTAssertEqual(teams.map(\.canAdd), [true, true, false])
    }

    func testUpload() throws {
        let request = try XCTUnwrap(TeamPool.uploadBody(provider: .grok, label: "me@example.com", credentials: body(auth)))
        XCTAssertEqual(request["provider"] as? String, "grok")
        XCTAssertEqual(request["label"] as? String, "me@example.com")
        XCTAssertNotNil(request["credentials"] as? [String: Any])
        XCTAssertEqual(TeamPool.uploadBody(provider: .grok, label: " ", credentials: body(auth))?["label"] as? String, "Grok account")
        XCTAssertNil(TeamPool.uploadBody(provider: .codex, label: "x", credentials: body(auth)))
        XCTAssertNil(TeamPool.uploadBody(provider: .claude, label: "x", credentials: body(auth)))

        let row: [String: Any] = ["id": "g", "provider": "grok", "label": "me@example.com", "enabled": true]
        XCTAssertEqual(try TeamPool.uploaded(status: 201, body: ok(["account": row]), team: team).id, "g")
        XCTAssertEqual(try TeamPool.uploaded(status: 200, body: ok(["account": row]), team: team).label, "me@example.com")
        XCTAssertThrowsError(try TeamPool.uploaded(status: 403, body: Data(), team: team)) { error in
            XCTAssertEqual((error as? TeamPool.Failure)?.message, "Only a team's owners and managers can add accounts.")
        }
        XCTAssertThrowsError(try TeamPool.uploaded(status: 400, body: body(["ok": false, "error": "secret-refresh"]), team: team)) { error in
            XCTAssertFalse((error as? TeamPool.Failure)?.message.contains("secret") ?? true)
        }
        XCTAssertThrowsError(try TeamPool.uploaded(status: 201, body: ok([:]), team: team))
    }

    func testResumeCommand() {
        XCTAssertEqual(AgentResume.grokCommandLine(userArgs: ["-m", "grok-4", "fix the bug", "--always-approve"], sessionID: "0199-abcd",
                                                   prompt: "Continue where you left off."),
                       "command grok --resume 0199-abcd Continue\\ where\\ you\\ left\\ off. -m grok-4 --always-approve")
        // Session choices and the leader socket are the new login's to pick.
        XCTAssertEqual(AgentResume.grokCommandLine(userArgs: ["--continue", "--leader-socket", "/x/leader.sock", "-r", "old", "--fork-session",
                                                              "--resume=older", "-s", "id", "--model=fast"], sessionID: "new"),
                       "command grok --resume new --model\\=fast")
        XCTAssertEqual(AgentResume.grokCommandLine(userArgs: ["-r", "--always-approve"], sessionID: "new"),
                       "command grok --resume new --always-approve")
        // One-shot runs, subcommands and worktree runs aren't resumed.
        XCTAssertNil(AgentResume.grokCommandLine(userArgs: ["-p", "hi"], sessionID: "new"))
        XCTAssertNil(AgentResume.grokCommandLine(userArgs: ["--prompt-file", "x"], sessionID: "new"))
        XCTAssertNil(AgentResume.grokCommandLine(userArgs: ["login"], sessionID: "new"))
        XCTAssertNil(AgentResume.grokCommandLine(userArgs: ["-w"], sessionID: "new"))
    }

    func testNewSessionsGetAnIDOfAgterms() {
        let make = { "new-id" }
        XCTAssertEqual(GrokSessions.launch(["-m", "fast", "fix it"], newID: make).extra, ["--session-id", "new-id"])
        XCTAssertEqual(GrokSessions.launch([], newID: make).sessionID, "new-id")
        // A conversation you picked is known; one Grok picks isn't, and gets no id of ours.
        XCTAssertEqual(GrokSessions.launch(["--resume", "abc"], newID: make).sessionID, "abc")
        XCTAssertEqual(GrokSessions.launch(["--resume=abc"], newID: make).sessionID, "abc")
        XCTAssertEqual(GrokSessions.launch(["-s", "mine"], newID: make).sessionID, "mine")
        XCTAssertTrue(GrokSessions.launch(["-s", "mine"], newID: make).extra.isEmpty)
        for args in [["--continue"], ["-r"], ["-r", "--model", "x"], ["--resume", "abc", "--fork-session"], ["-p", "hi"], ["login"], ["--version"]] {
            let launch = GrokSessions.launch(args, newID: make)
            XCTAssertNil(launch.sessionID, "\(args)")
            XCTAssertTrue(launch.extra.isEmpty, "\(args)")
        }
        XCTAssertEqual(GrokSessions.folder(userArgs: ["--cwd", "/src/app"], processCwd: "/home"), "/src/app")
        XCTAssertEqual(GrokSessions.folder(userArgs: ["--cwd=/src/app"], processCwd: "/home"), "/src/app")
        XCTAssertEqual(GrokSessions.folder(userArgs: [], processCwd: "/home"), "/home")
    }

    func testOnlyConversationWrittenInAFolder() throws {
        let sessions = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessions) }
        let project = sessions.appendingPathComponent("%2Ftmp%2Fmy%20project")
        let other = sessions.appendingPathComponent("%2Ftmp%2Fother")
        func write(_ dir: URL, _ id: String, at date: Date) throws {
            let folder = dir.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("chat_history.jsonl")
            try Data("{}\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        try write(project, "0199aaaa-old", at: now.addingTimeInterval(-600))
        try write(project, "0199bbbb-new", at: now.addingTimeInterval(-10))
        try write(other, "0199cccc-elsewhere", at: now)
        XCTAssertEqual(GrokSessions.written(in: sessions, cwd: "/tmp/my project", since: now.addingTimeInterval(-60)), "0199bbbb-new")
        // Nothing written since the agent started, or two conversations were: no guess.
        XCTAssertNil(GrokSessions.written(in: sessions, cwd: "/tmp/my project", since: now))
        XCTAssertNil(GrokSessions.written(in: sessions, cwd: "/tmp/my project", since: now.addingTimeInterval(-3600)))
        XCTAssertNil(GrokSessions.written(in: sessions, cwd: "/tmp/none", since: .distantPast))
    }
}
