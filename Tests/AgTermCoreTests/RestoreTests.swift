import XCTest
@testable import AgTermCore

final class AgentResumeTests: XCTestCase {
    func testClaudeResumesItsExactSessionWithOriginalFlags() {
        let line = AgentResume.commandLine(argv: ["claude", "--dangerously-skip-permissions"], claudeSessionID: "abc-123")
        XCTAssertEqual(line, "command claude --resume abc-123 --dangerously-skip-permissions")
    }

    func testOldResumeContinueAndPromptAreDropped() {
        let argv = ["/Users/sam/.local/bin/claude", "--model", "opus", "-r", "old-id", "-c", "fix the login bug"]
        XCTAssertEqual(AgentResume.commandLine(argv: argv, claudeSessionID: "new-id"),
                       "command claude --resume new-id --model opus")
    }

    func testPrintModeIsNotResumed() {
        XCTAssertNil(AgentResume.commandLine(argv: ["claude", "-p", "summarize"], claudeSessionID: "x"))
    }

    func testClaudeWithoutKnownSessionContinuesLatestInFolder() {
        XCTAssertEqual(AgentResume.commandLine(argv: ["claude"], claudeSessionID: nil), "command claude --continue")
    }

    func testNodeInstalledClaudeIsRecognised() {
        let argv = ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--verbose"]
        XCTAssertEqual(AgentResume.commandLine(argv: argv, claudeSessionID: "s"), "command claude --resume s --verbose")
    }

    func testOtherProgramsAreNotRerun() {
        XCTAssertNil(AgentResume.commandLine(argv: ["rm", "-rf", "build"], claudeSessionID: nil))
        XCTAssertNil(AgentResume.commandLine(argv: ["npm", "run", "dev"], claudeSessionID: nil))
        XCTAssertNil(AgentResume.commandLine(argv: [], claudeSessionID: nil))
    }

    func testArgumentsWithSpacesAreEscaped() {
        XCTAssertEqual(AgentResume.commandLine(argv: ["claude", "--add-dir", "/My Code"], claudeSessionID: "s"),
                       #"command claude --resume s --add-dir /My\ Code"#)
    }
}

final class SGRTests: XCTestCase {
    func testDefaultCellResets() {
        XCTAssertEqual(SGR.sequence(fg: .default, bg: .default, style: []), "\u{1b}[0m")
    }

    func testColorsAndStyles() {
        XCTAssertEqual(SGR.sequence(fg: .ansi(1), bg: .default, style: [.bold]), "\u{1b}[0;1;31m")
        XCTAssertEqual(SGR.sequence(fg: .ansi(9), bg: .ansi(4), style: []), "\u{1b}[0;91;44m")
        XCTAssertEqual(SGR.sequence(fg: .ansi(208), bg: .rgb(1, 2, 3), style: [.italic, .underline]),
                       "\u{1b}[0;3;4;38;5;208;48;2;1;2;3m")
    }
}

final class TabOrderTests: XCTestCase {
    func testMovingTheSelectedTabKeepsItSelected() {
        XCTAssertEqual(TabOrder.selection(afterMoving: 0, to: 2, selected: 0), 2)
    }

    func testOtherTabsShiftAroundTheMove() {
        XCTAssertEqual(TabOrder.selection(afterMoving: 0, to: 2, selected: 1), 0)
        XCTAssertEqual(TabOrder.selection(afterMoving: 3, to: 1, selected: 2), 3)
        XCTAssertEqual(TabOrder.selection(afterMoving: 3, to: 1, selected: 0), 0)
    }

    func testArrayMove() {
        XCTAssertEqual(TabOrder.moved(["a", "b", "c", "d"], from: 0, to: 2), ["b", "c", "a", "d"])
        XCTAssertEqual(TabOrder.moved(["a", "b", "c", "d"], from: 3, to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(TabOrder.moved(["a", "b"], from: 1, to: 5), ["a", "b"], "out of range is a no-op")
    }
}

final class SavedWorkspaceTests: XCTestCase {
    func testRoundTripThroughJSON() throws {
        let workspace = SavedWorkspace(selected: 1, tabs: [
            SavedTab(cwd: "/Users/sam/web", scrollback: "\u{1b}[0;32mok\u{1b}[0m\nnext", resume: "command claude --resume s"),
            SavedTab(cwd: "/tmp", scrollback: "", resume: nil),
        ])
        let data = try workspace.encoded()
        XCTAssertEqual(try SavedWorkspace.decode(data), workspace)
    }

    func testUnknownVersionIsIgnored() {
        let data = Data(#"{"version": 99, "selected": 0, "tabs": [], "savedAt": 0}"#.utf8)
        XCTAssertNil(try? SavedWorkspace.decode(data))
    }

    func testSelectionIsClampedToTabs() throws {
        let data = Data(#"{"version": 1, "selected": 7, "savedAt": 0, "tabs": [{"cwd": "/a", "scrollback": ""}]}"#.utf8)
        XCTAssertEqual(try SavedWorkspace.decode(data).selected, 0)
    }
}
