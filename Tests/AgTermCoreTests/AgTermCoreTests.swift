import XCTest
@testable import AgTermCore

final class TitleParserTests: XCTestCase {
    func testClaudeIdleTitle() {
        let t = TitleParser.parse("✳ Infocusportal.com domain switch")
        XCTAssertEqual(t, ParsedTitle(topic: "Infocusportal.com domain switch", activity: .idle))
    }

    func testBrailleSpinnerMeansWorking() {
        let t = TitleParser.parse("⠐ Editor anchor masking")
        XCTAssertEqual(t, ParsedTitle(topic: "Editor anchor masking", activity: .working))
    }

    func testClaudeCodeHalfCircleSpinnerIsWorking() {
        // Recorded from Claude Code 2.1.310: "◐ Ok", "◑ Ok", then "✳ Ok" when the turn ends.
        XCTAssertEqual(TitleParser.parse("◐ Simple acknowledgment reply"),
                       ParsedTitle(topic: "Simple acknowledgment reply", activity: .working))
        XCTAssertEqual(TitleParser.parse("◑ Ok"), ParsedTitle(topic: "Ok", activity: .working))
    }

    func testGrokStatusIsDropped() {
        XCTAssertEqual(TitleParser.parse("⠋ - Thinking - Major load-speed performance"),
                       ParsedTitle(topic: "Major load-speed performance", activity: .working))
        XCTAssertEqual(TitleParser.parse("- Waiting for response... - Major load-speed performance"),
                       ParsedTitle(topic: "Major load-speed performance", activity: .unknown))
    }

    func testPlainTitleIsUnknown() {
        XCTAssertEqual(TitleParser.parse("vim notes.md"), ParsedTitle(topic: "vim notes.md", activity: .unknown))
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(TitleParser.parse("   "), ParsedTitle(topic: "", activity: .unknown))
        XCTAssertEqual(TitleParser.parse("✳"), ParsedTitle(topic: "", activity: .idle))
    }
}

final class GitStatTests: XCTestCase {
    func testShortstatFull() {
        let s = GitStat.parseShortstat(" 3 files changed, 12 insertions(+), 4 deletions(-)\n")
        XCTAssertEqual(s.added, 12)
        XCTAssertEqual(s.removed, 4)
    }

    func testShortstatPartial() {
        XCTAssertEqual(GitStat.parseShortstat(" 1 file changed, 1 insertion(+)").added, 1)
        XCTAssertEqual(GitStat.parseShortstat(" 1 file changed, 2 deletions(-)").removed, 2)
        XCTAssertEqual(GitStat.parseShortstat("").added, 0)
    }

    func testPorcelainBranchAndFiles() {
        let out = "## master...origin/master [ahead 1]\n M a.txt\n?? b.txt\nA  c.txt\n"
        let p = GitStat.parsePorcelain(out)
        XCTAssertEqual(p.branch, "master")
        XCTAssertEqual(p.files, 3)
    }

    func testPorcelainNoUpstreamAndNoCommits() {
        XCTAssertEqual(GitStat.parsePorcelain("## feat/x\n").branch, "feat/x")
        XCTAssertEqual(GitStat.parsePorcelain("## No commits yet on main\n?? a\n").branch, "main")
    }
}

final class StatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)

    private func signals(_ build: (inout StatusSignals) -> Void) -> StatusSignals {
        var s = StatusSignals()
        build(&s)
        return s
    }

    func testExitedWins() {
        XCTAssertEqual(StatusRules.status(signals { $0.exited = true; $0.titleActivity = .working }, now: now), .exited)
    }

    func testTitleSpinnerIsWorking() {
        XCTAssertEqual(StatusRules.status(signals { $0.titleActivity = .working }, now: now), .working)
    }

    func testClaudeIdleIgnoresOutputNoise() {
        let s = signals { $0.titleActivity = .idle; $0.lastOutput = now }
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testPlainOutputIsWorking() {
        let s = signals { $0.lastInput = now.addingTimeInterval(-3); $0.lastOutput = now.addingTimeInterval(-0.5) }
        XCTAssertEqual(StatusRules.status(s, now: now), .working)
    }

    func testStartupOutputBeforeAnyInputIsNotWorking() {
        let s = signals { $0.lastOutput = now.addingTimeInterval(-0.2) }
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testTypingEchoIsNotWorking() {
        let s = signals { $0.lastInput = now.addingTimeInterval(-0.4); $0.lastOutput = now.addingTimeInterval(-0.3) }
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testRedrawAfterResizeIsNotWorking() {
        let s = signals {
            $0.lastInput = now.addingTimeInterval(-30)
            $0.lastResize = now.addingTimeInterval(-0.4)
            $0.lastOutput = now.addingTimeInterval(-0.3)
        }
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testBellAtEndOfWorkIsWaiting() {
        // The bell can arrive in the same tick that last saw the spinner.
        let s = signals {
            $0.lastSeen = now.addingTimeInterval(-60)
            $0.lastBell = now.addingTimeInterval(-5.2)
            $0.lastWorking = now.addingTimeInterval(-5)
            $0.titleActivity = .idle
        }
        XCTAssertEqual(StatusRules.status(s, now: now), .waiting)
    }

    func testWorkAfterBellIsDoneNotWaiting() {
        let s = signals {
            $0.lastSeen = now.addingTimeInterval(-60)
            $0.lastBell = now.addingTimeInterval(-30)
            $0.lastWorking = now.addingTimeInterval(-5)
            $0.titleActivity = .idle
        }
        XCTAssertEqual(StatusRules.status(s, now: now), .done)
    }

    func testFinishedWhileAwayIsDone() {
        let s = signals { $0.lastWorking = now.addingTimeInterval(-5); $0.lastSeen = now.addingTimeInterval(-60) }
        XCTAssertEqual(StatusRules.status(s, now: now), .done)
    }

    func testPauseInARunningCommandIsNotDone() {
        // `brew upgrade` goes quiet between casks; that isn't the command finishing.
        let s = signals {
            $0.lastWorking = now.addingTimeInterval(-5)
            $0.lastSeen = now.addingTimeInterval(-60)
            $0.commandRunning = true
        }
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
        var finished = s
        finished.commandRunning = false
        XCTAssertEqual(StatusRules.status(finished, now: now), .done)
    }

    func testFocusedTabNeverDone() {
        let s = signals { $0.lastWorking = now.addingTimeInterval(-5); $0.lastSeen = now.addingTimeInterval(-60); $0.focused = true }
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testBellWhileAwayIsWaiting() {
        let s = signals { $0.lastBell = now.addingTimeInterval(-1); $0.lastSeen = now.addingTimeInterval(-10); $0.titleActivity = .idle }
        XCTAssertEqual(StatusRules.status(s, now: now), .waiting)
    }
}

final class PathDisplayTests: XCTestCase {
    func testFolderName() {
        XCTAssertEqual(PathDisplay.folder("/Users/sam/code/agterm", home: "/Users/sam"), "agterm")
        XCTAssertEqual(PathDisplay.folder("/Users/sam", home: "/Users/sam"), "~")
        XCTAssertEqual(PathDisplay.folder("/", home: "/Users/sam"), "/")
    }
}

final class ClaudeSessionTitleTests: XCTestCase {
    func testAITitleWins() {
        let lines = """
        {"type":"last-prompt","lastPrompt":"fix the login page","sessionId":"s"}
        {"type":"ai-title","aiTitle":"Login page fix","sessionId":"s"}
        {"type":"ai-title","aiTitle":"Login page redirect fix","sessionId":"s"}
        """
        XCTAssertEqual(ClaudeSessionTitle.parse(lines: lines), "Login page redirect fix")
    }

    func testSlashCommandFirstPromptFallsBackToItsArguments() {
        // Recorded from Claude Code 2.1.310: a session opened with a skill command never gets an ai-title.
        let lines = """
        {"type":"last-prompt","leafUuid":"a","sessionId":"s"}
        {"type":"user","message":{"role":"user","content":"<command-name>/workflow-authoring</command-name>"}}
        {"type":"last-prompt","lastPrompt":"/workflow-authoring Make some UI fixes\\nand more","sessionId":"s"}
        {"type":"last-prompt","lastPrompt":"later prompt","sessionId":"s"}
        """
        XCTAssertEqual(ClaudeSessionTitle.parse(lines: lines), "Make some UI fixes")
    }

    func testBareSlashCommandAndEmptyTranscriptHaveNoTitle() {
        XCTAssertNil(ClaudeSessionTitle.parse(lines: #"{"type":"last-prompt","lastPrompt":"/model","sessionId":"s"}"#))
        XCTAssertNil(ClaudeSessionTitle.parse(lines: ""))
    }

    func testGenericTopic() {
        XCTAssertTrue(ClaudeSessionTitle.isGeneric(""))
        XCTAssertTrue(ClaudeSessionTitle.isGeneric("Claude Code"))
        XCTAssertFalse(ClaudeSessionTitle.isGeneric("Login page fix"))
    }
}
