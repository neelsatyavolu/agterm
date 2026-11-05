@testable import AgTermCore
import XCTest

final class TeamSessionsWireTests: XCTestCase {
    func testReportsOnlyAgentTabsWithAFolderNameNotAPath() {
        XCTAssertNil(TeamSessionsWire.session(tabID: "t", agent: nil, topic: "zsh", cwd: "/Users/a/x", branch: nil,
                                              status: .idle, conversation: nil))
        let s = TeamSessionsWire.session(tabID: "t1", agent: "claude", topic: "Fix login", cwd: "/Users/a/src/web",
                                         branch: "main", status: .working, conversation: "abc")
        XCTAssertEqual(s, .init(key: "t1", agent: "claude", title: "Fix login", project: "web", branch: "main",
                                status: "working", canAsk: true))
    }

    func testOnlyClaudeWithAKnownConversationCanBeAsked() {
        func canAsk(_ agent: String, _ conversation: String?) -> Bool? {
            TeamSessionsWire.session(tabID: "t", agent: agent, topic: "", cwd: "/r", branch: nil, status: .idle,
                                     conversation: conversation)?.canAsk
        }
        XCTAssertEqual(canAsk("claude", "id"), true)
        XCTAssertEqual(canAsk("claude", nil), false)
        // Codex's read-only copy can read files outside the tab's folder.
        XCTAssertEqual(canAsk("codex", "id"), false)
        XCTAssertEqual(canAsk("grok", "id"), false)
    }

    func testStatusNamesMatchTheServer() {
        XCTAssertEqual(TeamSessionsWire.reportedStatus(.waiting), "needs_you")
        XCTAssertEqual(TeamSessionsWire.reportedStatus(.done), "done")
        XCTAssertEqual(TeamSessionsWire.reportedStatus(.exited), "idle")
    }

    func testAMessageIsTypedAsOneMarkedLine() {
        let typed = TeamSessionsWire.typedMessage(from: "Alice", body: "I moved main.\n\n  Rebase onto it.\r\n")
        XCTAssertFalse(typed.contains("\n"))
        XCTAssertFalse(typed.contains("\r"))
        XCTAssertTrue(typed.hasPrefix("[Message from Alice's agent through agmux Teams."))
        XCTAssertTrue(typed.hasSuffix("] I moved main. Rebase onto it."))
    }

    func testControlCharactersCannotSteerTheTerminalOrEraseTheMarking() {
        let typed = TeamSessionsWire.typedMessage(from: "Eve\u{1b}[2K", body: "hi\u{15}\u{3}\u{1b}[2Jrm -rf\u{2028}now")
        XCTAssertFalse(typed.unicodeScalars.contains { $0.properties.generalCategory == .control })
        XCTAssertTrue(typed.hasPrefix("[Message from Eve [2K's agent through agmux Teams."))
        XCTAssertTrue(typed.hasSuffix("] hi [2Jrm -rf now"))
    }

    func testInboxRequestsDecodeFromTheServer() throws {
        let json = #"{"id":"tsr_1","sessionKey":"tab","kind":"ask","body":"why?","effort":null,"from":"Bob"}"#
        let request = try JSONDecoder().decode(TeamSessionsWire.InboxRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.from, "Bob")
        XCTAssertNil(request.effort)
    }

    func testAnswerRequestCarriesTheConversationAndEffort() throws {
        let data = TeamSessionsWire.answerRequest(agent: "claude", conversation: "c-1", cwd: "/r", question: "q", effort: "low")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["agent": "claude", "sessionId": "c-1", "cwd": "/r", "question": "q", "effort": "low"])
    }
}
