@testable import AgTermCore
import XCTest

final class HandoffTests: XCTestCase {
    private func row(_ kind: String, _ text: String? = nil, lead: String? = nil, subject: String? = nil,
                     detail: String? = nil, additions: Int? = nil, deletions: Int? = nil, n: Int = 0) -> MobileTimelineEntry {
        MobileTimelineEntry(id: "\(kind)-\(n)", kind: kind, text: text, lead: lead, subject: subject, detail: detail,
                            additions: additions, deletions: deletions, ts: 0)
    }

    // MARK: Command lines

    func testCommandLinesStartInteractiveSessions() {
        XCTAssertEqual(HandoffTarget.claude.commandLine(prompt: "go"), "claude go")
        XCTAssertEqual(HandoffTarget.codex.commandLine(prompt: "go"), "codex go")
        XCTAssertEqual(HandoffTarget.grok.commandLine(prompt: "go"), "grok go")
        XCTAssertEqual(HandoffTarget.gemini.commandLine(prompt: "go"), "gemini -i go")
    }

    func testPromptIsEscapedForTheShell() {
        let line = HandoffTarget.claude.commandLine(prompt: #"Read "a b" for $HOME's `x`"#)
        XCTAssertEqual(line, #"claude Read\ \"a\ b\"\ for\ \$HOME\'s\ \`x\`"#)
    }

    func testTitlesComeFromAgentKinds() {
        XCTAssertEqual(HandoffTarget.claude.title, "Claude Code")
        XCTAssertEqual(HandoffTarget.gemini.title, "Gemini CLI")
    }

    func testPromptNamesAgentAndPath() {
        let prompt = Handoff.prompt(briefPath: "/r/.git/agterm/handoffs/x.md", fromAgent: "claude")
        XCTAssertTrue(prompt.contains("Claude Code"))
        XCTAssertTrue(prompt.contains("/r/.git/agterm/handoffs/x.md"))
        XCTAssertFalse(prompt.contains("\n"))
    }

    // MARK: Brief

    func testBriefFormatsRowsAndDropsThinking() {
        let brief = Handoff.brief(entries: [
            row("user", "Fix the login bug", n: 1),
            row("thinking", "secret musing", n: 2),
            row("tool", lead: "Edited", subject: "Sources/Login.swift", additions: 3, deletions: 1, n: 3),
            row("tool", lead: "Ran", subject: "swift test", n: 4),
            row("assistant", "Fixed it.", n: 5),
        ], fromAgent: "codex", cwd: "/repo", branch: "main")
        XCTAssertTrue(brief.contains("Codex"))
        XCTAssertTrue(brief.contains("/repo"))
        XCTAssertTrue(brief.contains("main"))
        XCTAssertTrue(brief.contains("Fix the login bug"))
        XCTAssertTrue(brief.contains("- Edited Sources/Login.swift (+3 −1)"))
        XCTAssertTrue(brief.contains("- Ran `swift test`"))
        XCTAssertTrue(brief.contains("Fixed it."))
        XCTAssertFalse(brief.contains("secret musing"))
    }

    func testBriefIsDeterministic() {
        let entries = [row("user", "a", n: 1)]
        XCTAssertEqual(Handoff.brief(entries: entries, fromAgent: "claude", cwd: "/r", branch: nil),
                       Handoff.brief(entries: entries, fromAgent: "claude", cwd: "/r", branch: nil))
    }

    func testOverBudgetKeepsFirstTaskAndRecentRows() {
        var entries = [row("user", "ORIGINAL TASK", n: 0)]
        for i in 1...200 { entries.append(row("assistant", "step \(i) " + String(repeating: "x", count: 200), n: i)) }
        let brief = Handoff.brief(entries: entries, fromAgent: "claude", cwd: "/r", branch: nil, maxCharacters: 5000)
        XCTAssertLessThanOrEqual(brief.count, 5000)
        XCTAssertTrue(brief.contains("ORIGINAL TASK"))
        XCTAssertTrue(brief.contains("step 200 "))
        XCTAssertFalse(brief.contains("step 1 "))
        XCTAssertTrue(brief.contains("earlier steps left out"))
        // The original task comes before the marker, which comes before recent rows.
        let task = brief.range(of: "ORIGINAL TASK")!.lowerBound
        let marker = brief.range(of: "earlier steps left out")!.lowerBound
        let recent = brief.range(of: "step 200 ")!.lowerBound
        XCTAssertTrue(task < marker && marker < recent)
    }

    func testLongSingleTextIsCutInTheMiddle() {
        let text = "HEAD" + String(repeating: "m", count: 50_000) + "TAIL"
        let brief = Handoff.brief(entries: [row("user", text)], fromAgent: "claude", cwd: "/r", branch: nil, maxCharacters: 4000)
        XCTAssertLessThanOrEqual(brief.count, 4000)
        XCTAssertTrue(brief.contains("HEAD"))
        XCTAssertTrue(brief.contains("TAIL"))
    }

    func testScreenFallbackKeepsTheEnd() {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let brief = Handoff.brief(screen: text, fromAgent: "aider", cwd: "/r", branch: "dev", maxCharacters: 2000)
        XCTAssertLessThanOrEqual(brief.count, 2000)
        XCTAssertTrue(brief.contains("line 500"))
        XCTAssertFalse(brief.contains("line 1\n"))
        XCTAssertTrue(brief.contains("```"))
        XCTAssertTrue(brief.contains("Aider"))
    }
}
