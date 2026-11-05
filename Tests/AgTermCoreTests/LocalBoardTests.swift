@testable import AgTermCore
import XCTest

final class LocalBoardTests: XCTestCase {
    private let project = "github.com/acme/web"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaimQuestionAndReplyShowNewestFirstForTheirRepoOnly() throws {
        var board = LocalBoard()
        _ = try board.post(project: project, kind: "claim", text: "Taking migration 365", replyTo: nil, hours: nil,
                           agent: "codex", now: t0, id: "c")
        _ = try board.post(project: project, kind: "question", text: "Anyone on auth.ts?", replyTo: nil, hours: nil,
                           agent: "claude", now: t0 + 1, id: "q")
        _ = try board.post(project: project, kind: "reply", text: "Me, until 3pm", replyTo: "q", hours: nil,
                           agent: "grok", now: t0 + 2, id: "r")
        _ = try board.post(project: "github.com/acme/api", kind: "note", text: "elsewhere", replyTo: nil, hours: nil,
                           agent: nil, now: t0 + 3, id: "n")
        let rows = board.read(project: project, since: nil, now: t0 + 10, member: "You")
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["r", "q", "c"])
        XCTAssertEqual(rows.last?["expires"] as? String, ISO8601DateFormatter().string(from: t0 + 4 * 3600))
        XCTAssertEqual(rows.first?["reply_to"] as? String, "q")
        XCTAssertEqual(board.read(project: project, since: t0 + 2, now: t0 + 10, member: "You").count, 1)
    }

    func testClaimsExpireUnlessRenewedAndCanBeClosed() throws {
        var board = LocalBoard()
        _ = try board.post(project: project, kind: "claim", text: "deploy", replyTo: nil, hours: 1, agent: nil, now: t0, id: "c")
        XCTAssertEqual(board.read(project: project, since: nil, now: t0 + 7200, member: "You").first?["status"] as? String, "expired")
        // A read since before it ran out shows the change, though nobody touched it.
        XCTAssertEqual(board.read(project: project, since: t0 + 1800, now: t0 + 7200, member: "You").first?["status"] as? String, "expired")
        try board.update(id: "c", status: nil, renew: true, hours: 2, text: nil, now: t0 + 7200)
        XCTAssertEqual(board.read(project: project, since: nil, now: t0 + 7300, member: "You").first?["status"] as? String, "open")
        try board.update(id: "c", status: "done", renew: false, hours: nil, text: nil, now: t0 + 7400)
        XCTAssertEqual(board.items.first?.status, "done")
    }

    func testRefusesBadInputAndStripsControlCharacters() throws {
        var board = LocalBoard()
        XCTAssertThrowsError(try board.post(project: project, kind: "shout", text: "x", replyTo: nil, hours: nil, agent: nil, now: t0))
        XCTAssertThrowsError(try board.post(project: project, kind: "note", text: "  ", replyTo: nil, hours: nil, agent: nil, now: t0))
        XCTAssertThrowsError(try board.post(project: project, kind: "reply", text: "x", replyTo: "nope", hours: nil, agent: nil, now: t0)) {
            XCTAssertEqual($0 as? LocalBoard.Failure, .notFound)
        }
        let item = try board.post(project: project, kind: "note", text: "hi\u{1b}[2J\u{15}there", replyTo: nil, hours: nil, agent: nil, now: t0)
        XCTAssertEqual(item.text, "hi [2J there")
        XCTAssertThrowsError(try board.update(id: item.id, status: nil, renew: true, hours: nil, text: nil, now: t0))
    }

    func testSweepKeepsHeldClaimsAndDecisionsLongest() throws {
        var board = LocalBoard()
        _ = try board.post(project: project, kind: "decision", text: "UUIDv7", replyTo: nil, hours: nil, agent: nil, now: t0, id: "d")
        _ = try board.post(project: project, kind: "note", text: "fyi", replyTo: nil, hours: nil, agent: nil, now: t0, id: "n")
        _ = try board.post(project: project, kind: "claim", text: "old", replyTo: nil, hours: 1, agent: nil, now: t0, id: "c")
        board.sweep(now: t0 + 30 * 86_400)
        XCTAssertEqual(board.items.map(\.id), ["d"])
    }

    func testSurvivesASaveAndLoad() throws {
        var board = LocalBoard()
        _ = try board.post(project: project, kind: "claim", text: "x", replyTo: nil, hours: nil, agent: "claude", now: t0, id: "c")
        let data = try JSONEncoder().encode(board)
        XCTAssertEqual(try JSONDecoder().decode(LocalBoard.self, from: data), board)
    }
}
