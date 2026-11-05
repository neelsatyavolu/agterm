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

    func testOtherAgentsContinueTheirLatestConversation() {
        XCTAssertEqual(AgentResume.continueCommandLine(agent: "grok", argv: ["grok", "--model", "x"]), "command grok --continue")
        XCTAssertEqual(AgentResume.continueCommandLine(agent: "gemini", argv: ["node", "/x/gemini"]), "command gemini --resume latest")
        XCTAssertEqual(AgentResume.continueCommandLine(agent: "goose", argv: ["goose", "session"]), "command goose session --resume")
        // One-shot runs and agents with no way back aren't rerun; Claude and Codex resume exactly instead.
        XCTAssertNil(AgentResume.continueCommandLine(agent: "grok", argv: ["grok", "-p", "hi"]))
        XCTAssertNil(AgentResume.continueCommandLine(agent: "qodo", argv: ["qodo"]))
        XCTAssertNil(AgentResume.continueCommandLine(agent: "claude", argv: ["claude"]))
        XCTAssertNil(AgentResume.continueCommandLine(agent: "codex", argv: ["codex"]))
    }

    func testCodexResumesItsExactSessionWithOriginalFlags() {
        XCTAssertEqual(AgentResume.codexCommandLine(userArgs: ["-m", "gpt-x", "fix the bug", "--yolo"], sessionID: "0199-abc"),
                       "command codex resume 0199-abc -m gpt-x --yolo")
    }

    func testOldSaveWithoutSessionIDDecodes() throws {
        let data = Data(#"{"version": 1, "selected": 0, "savedAt": 0, "tabs": [{"cwd": "/a", "scrollback": "x", "resume": "command claude --continue"}]}"#.utf8)
        let tab = try XCTUnwrap(try SavedWorkspace.decode(data).tabs.first)
        XCTAssertEqual(tab.cwd, "/a")
        XCTAssertEqual(tab.resume, "command claude --continue")
        XCTAssertNil(tab.sessionID)
        XCTAssertNil(tab.tabID)
    }

    func testSessionIDRoundTrips() throws {
        let workspace = SavedWorkspace(selected: 0, tabs: [
            SavedTab(cwd: "/a", scrollback: "", resume: nil, sessionID: "5F0C2A1E-0000-4000-8000-000000000001", tabID: "T1"),
            SavedTab(cwd: "/b", scrollback: "", resume: nil),
        ])
        let decoded = try SavedWorkspace.decode(workspace.encoded())
        XCTAssertEqual(decoded.tabs.map(\.sessionID), ["5F0C2A1E-0000-4000-8000-000000000001", nil])
        XCTAssertEqual(decoded.tabs.map(\.tabID), ["T1", nil])
    }

    func testLaunchReattachesListedTabsRestoresOthersAndAppendsOrphans() {
        let date = Date(timeIntervalSince1970: 0)
        let a = SessionInfo(id: "A", pid: 10, cwd: "/a", startedAt: date)
        let orphan = SessionInfo(id: "O", pid: 30, cwd: "/o", startedAt: date)
        let kept = SavedTab(cwd: "/a", scrollback: "", resume: nil, sessionID: "A")
        let gone = SavedTab(cwd: "/b", scrollback: "old", resume: "command claude --continue", sessionID: "B")
        let old = SavedTab(cwd: "/c", scrollback: "", resume: nil)
        XCTAssertEqual(LaunchTab.plan(saved: [gone, kept, old], live: [orphan, a]),
                       [.restore(gone), .reattach(a, saved: kept), .restore(old), .reattach(orphan, saved: nil)])
    }

    func testLaunchReattachesASessionOnlyOnce() {
        let a = SessionInfo(id: "A", pid: 10, cwd: "/a", startedAt: Date(timeIntervalSince1970: 0))
        let tab = SavedTab(cwd: "/a", scrollback: "", resume: nil, sessionID: "A")
        XCTAssertEqual(LaunchTab.plan(saved: [tab, tab], live: [a]), [.reattach(a, saved: tab), .restore(tab)])
    }

    func testLaunchLeavesOutSessionsAttachedElsewhere() {
        let date = Date(timeIntervalSince1970: 0)
        let other = SessionInfo(id: "A", pid: 10, cwd: "/a", startedAt: date, attached: true)
        let stray = SessionInfo(id: "S", pid: 20, cwd: "/s", startedAt: date, attached: true)
        let free = SessionInfo(id: "F", pid: 30, cwd: "/f", startedAt: date)
        let shown = SavedTab(cwd: "/a", scrollback: "", resume: "command claude --continue", sessionID: "A")
        let plain = SavedTab(cwd: "/b", scrollback: "", resume: nil)
        // Another agterm shows A and S: neither is taken, and A's saved tab isn't restored or resumed either.
        XCTAssertEqual(LaunchTab.plan(saved: [shown, plain], live: [other, stray, free]),
                       [.restore(plain), .reattach(free, saved: nil)])
    }

    func testLaunchWithoutTheHelperRestoresHistoryButDoesNotResume() {
        let kept = SavedTab(cwd: "/a", scrollback: "old", resume: "command claude --continue", sessionID: "A")
        let plain = SavedTab(cwd: "/b", scrollback: "", resume: "command codex resume x")
        // The agent may still be running in the helper, so it isn't started a second time.
        XCTAssertEqual(LaunchTab.plan(saved: [kept, plain], live: nil),
                       [.restore(SavedTab(cwd: "/a", scrollback: "old", resume: nil, sessionID: "A")), .restore(plain)])
    }

    func testLaunchReattachesCloudTabsFromTheCloudMachine() {
        let date = Date(timeIntervalSince1970: 0)
        let local = SessionInfo(id: "L", pid: 10, cwd: "/a", startedAt: date)
        let remote = SessionInfo(id: "C", pid: 10, cwd: "/a", startedAt: date)
        let stray = SessionInfo(id: "S", pid: 11, cwd: "/s", startedAt: date)
        let here = SavedTab(cwd: "/a", scrollback: "", resume: nil, sessionID: "L")
        let there = SavedTab(cwd: "/a", scrollback: "", resume: "command claude --resume x", sessionID: "C", inCloud: true)
        XCTAssertEqual(LaunchTab.plan(saved: [there, here], live: [local], cloud: [remote, stray]),
                       [.reattachCloud(remote, saved: there), .reattach(local, saved: here), .reattachCloud(stray, saved: nil)])
        // A cloud id never matches this Mac's helper.
        XCTAssertEqual(LaunchTab.plan(saved: [there], live: [SessionInfo(id: "C", pid: 1, cwd: "/", startedAt: date)], cloud: []).first,
                       .restore(SavedTab(cwd: "/a", scrollback: "", resume: nil, sessionID: "C", inCloud: true)))
    }

    /// Its agent ran in the cloud: reopening it here must not start a second copy.
    func testUnreachableOrEndedCloudTabRestoresHistoryWithoutResuming() {
        let there = SavedTab(cwd: "/a", scrollback: "old", resume: "command claude --resume x", sessionID: "C", inCloud: true)
        var history = there
        history.resume = nil
        XCTAssertEqual(LaunchTab.plan(saved: [there], live: [], cloud: nil), [.restore(history)])
        XCTAssertEqual(LaunchTab.plan(saved: [there], live: [], cloud: []), [.restore(history)])
    }

    func testSelectionIsClampedToTabs() throws {
        let data = Data(#"{"version": 1, "selected": 7, "savedAt": 0, "tabs": [{"cwd": "/a", "scrollback": ""}]}"#.utf8)
        XCTAssertEqual(try SavedWorkspace.decode(data).selected, 0)
    }
}
