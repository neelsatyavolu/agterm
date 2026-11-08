@testable import AgTermCore
import XCTest

final class CodexSessionsTests: XCTestCase {
    private let id = "01a1bd26-0db4-7681-9acf-c411da42226a"

    func testResumedSessionFromArguments() {
        XCTAssertEqual(CodexSessions.resumed(["resume", id]), id)
        XCTAssertEqual(CodexSessions.resumed(["exec", "resume", id, "go on"]), id)
        XCTAssertEqual(CodexSessions.resumed(["-m", "gpt-5", "resume", "--all", id]), id)
        XCTAssertNil(CodexSessions.resumed(["resume", "--last"]), "--last doesn't name one")
        XCTAssertNil(CodexSessions.resumed(["resume"]), "the picker doesn't name one")
        XCTAssertNil(CodexSessions.resumed([id]), "a prompt, not a resume")
        XCTAssertNil(CodexSessions.resumed(["exec", "fix the resume flow"]))
    }

    /// A resumed rollout lives in the folder of the day it was first made.
    func testRolloutForSessionIsFoundInItsDayFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("2026/10/31"), today = root.appendingPathComponent("2026/11/08")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        let file = old.appendingPathComponent("rollout-2026-10-31T10-22-15-\(id).jsonl")
        try Data("{}\n".utf8).write(to: file)
        try Data("{}\n".utf8).write(to: today.appendingPathComponent("rollout-2026-11-08T13-52-30-01a1bd26-0db4-7cd3-a12f-9a641da20da2.jsonl"))
        XCTAssertEqual(CodexSessions.rollout(in: root, sessionID: id)?.lastPathComponent, file.lastPathComponent)
        XCTAssertNil(CodexSessions.rollout(in: root, sessionID: "01a1bd26-0db4-7681-9acf-000000000000"))
    }

    func testCodeModePatchLiterals() {
        XCTAssertEqual(CodexCodeMode.patches(#"text(await tools.apply_patch("*** Begin Patch\n*** End Patch\n"));"#),
                       ["*** Begin Patch\n*** End Patch\n"])
        XCTAssertEqual(CodexCodeMode.patches("await tools.apply_patch(`*** Begin Patch\n*** End Patch`)"), ["*** Begin Patch\n*** End Patch"])
        XCTAssertEqual(CodexCodeMode.patches("await tools.apply_patch(patch)"), [], "not a literal")
        XCTAssertEqual(CodexCodeMode.patches("await tools.exec_command({cmd: 'ls'})"), [])
    }
}
