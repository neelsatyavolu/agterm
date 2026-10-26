import XCTest
@testable import AgTermCore

final class PairLinkTests: XCTestCase {
    func testReadsAgtermLink() {
        let link = PairLink(url: URL(string: "agterm-remote://pair#pair=ABCD2345&desktopId=desk-1")!)
        XCTAssertEqual(link, PairLink(code: "ABCD2345", desktopId: "desk-1", relay: nil))
    }

    func testReadsAgmuxLinkAndQueryForm() {
        XCTAssertEqual(PairLink(url: URL(string: "https://remote.agmux.dev#pair=abcd2345&desktopId=d")!)?.code, "ABCD2345")
        XCTAssertEqual(PairLink(url: URL(string: "agterm-remote://pair?pair=X1&desktopId=d")!)?.desktopId, "d")
    }

    func testRoundTripsWithRelay() {
        let link = PairLink(code: "QWER5678", desktopId: "a-b", relay: "ws://127.0.0.1:8787/ws")
        XCTAssertEqual(PairLink(url: link.url), link)
        XCTAssertEqual(link.url.scheme, "agterm-remote")
    }

    func testRejectsIncompleteOrForeignLinks() {
        XCTAssertNil(PairLink(url: URL(string: "agterm-remote://pair#pair=ABC")!))
        XCTAssertNil(PairLink(url: URL(string: "https://example.com#pair=A&desktopId=d")!))
        XCTAssertNil(PairLink(url: URL(string: "agterm-remote://pair#pair=A&desktopId=d&relay=http://x/ws")!))
    }
}

final class TerminalKeyTests: XCTestCase {
    func testArrowsFollowCursorMode() {
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursor: false), "\u{1b}[A")
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursor: true), "\u{1b}OA")
        XCTAssertEqual(TerminalKey.esc.bytes(applicationCursor: true), "\u{1b}")
        XCTAssertEqual(TerminalKey.ctrlC.bytes(applicationCursor: false), "\u{3}")
        XCTAssertEqual(TerminalKey.shiftTab.bytes(applicationCursor: false), "\u{1b}[Z")
    }

    func testWireNames() {
        XCTAssertEqual(TerminalKey(rawValue: "enter"), .enter)
        XCTAssertNil(TerminalKey(rawValue: "rm -rf"))
    }
}

final class ScreenSnapshotTests: XCTestCase {
    func testColorWireRoundTrip() {
        for color in [CellColor.default, .ansi(0), .ansi(255), .rgb(1, 2, 3), .rgb(255, 255, 255)] {
            XCTAssertEqual(CellColor(wire: color.wire), color)
        }
        XCTAssertNil(CellColor.default.wire)
    }

    func testMergesRunsAndTrimsTrailingBlanks() {
        var line = ScreenLineBuilder()
        for ch in "ab" { line.add(ch, fg: .ansi(1), bg: .default, style: []) }
        line.add("c", fg: .ansi(2), bg: .default, style: .bold)
        for _ in 0..<5 { line.add(" ", fg: .default, bg: .default, style: []) }
        XCTAssertEqual(line.runs, [ScreenRun(t: "ab", f: 1), ScreenRun(t: "c", f: 2, s: CellStyle.bold.rawValue)])
    }

    func testKeepsTrailingColoredBackground() {
        var line = ScreenLineBuilder()
        line.add("x", fg: .default, bg: .default, style: [])
        line.add(" ", fg: .default, bg: .ansi(4), style: [])
        line.add(" ", fg: .default, bg: .default, style: [])
        XCTAssertEqual(line.runs, [ScreenRun(t: "x"), ScreenRun(t: " ", b: 4)])
    }

    func testEncodesCompactly() throws {
        let json = String(decoding: try JSONEncoder().encode(ScreenRun(t: "hi")), as: UTF8.self)
        XCTAssertEqual(json, #"{"t":"hi"}"#)
    }

    func testTrimToFitDropsOldestHistoryFirst() {
        let line = [ScreenRun(t: String(repeating: "x", count: 100))]
        var snap = ScreenSnapshot(cols: 100, rows: 2, lines: Array(repeating: line, count: 50), cursorRow: 49, cursorCol: 0, theme: "ink")
        snap.trim(toBytes: 2_000)
        XCTAssertLessThanOrEqual((try? JSONEncoder().encode(snap).count) ?? .max, 2_000)
        XCTAssertGreaterThanOrEqual(snap.lines.count, 2)
        XCTAssertEqual(snap.cursorRow, snap.lines.count - 1)
    }
}

final class PromptReadTests: XCTestCase {
    func testReadsClaudeChoices() {
        let screen = """
            ⏺ Bash(touch made.txt)
             Do you want to proceed?
             ❯ 1. Yes
               2. Yes, and always allow access to this folder
               3. No
             Esc to cancel · Tab to amend
            """.components(separatedBy: "\n")
        let prompt = PermissionPrompt.read(screen)
        XCTAssertEqual(prompt?.question, "Do you want to proceed?")
        XCTAssertEqual(prompt?.choices.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(prompt?.choices[1].label, "Yes, and always allow access to this folder")
        XCTAssertEqual(prompt?.choices.map(\.selected), [true, false, false])
    }

    func testReadsBoxedCodexChoices() {
        let prompt = PermissionPrompt.read(["│ Allow command? │", "│ › 1. Yes │", "│   2. No, tell Codex │", "│ esc cancel │"])
        XCTAssertEqual(prompt?.choices.map(\.label), ["Yes", "No, tell Codex"])
        XCTAssertEqual(prompt?.question, "Allow command?")
    }

    func testReadsCodexTrustPrompt() {
        let screen = """
            Folder access
            /private/tmp/agent-play

            Trust this folder? Codex can read, edit, and run files here, subject to your
            permission settings. Folder settings can run code automatically, even without
            a model request. Continue only if you trust these files. Your trust decision
            will be saved.

            › 1. Trust and continue
              2. Back to Agent Command Center

            enter continue · esc back
            """.components(separatedBy: "\n")
        let prompt = PermissionPrompt.read(screen)
        XCTAssertEqual(prompt?.question, "Trust this folder?")
        XCTAssertEqual(prompt?.choices.map(\.label), ["Trust and continue", "Back to Agent Command Center"])
    }

    func testHeadingWhenThereIsNoQuestion() {
        let screen = ["  Hooks need review", "› 1. Review hooks", "  2. Trust all and continue", "  enter confirm · esc skip"]
        XCTAssertEqual(PermissionPrompt.read(screen)?.question, "Hooks need review")
    }

    func testHeadingIsTheTopOfTheBlockAboveTheChoices() {
        let screen = """
            Set up security for Daybreak mode
            Set up Advanced Account Security with a hardware security key. Verify each
            new hardware security key with Persona. You can keep using Codex while you
            finish setup.

            › 1. Set up security

            Press a number to choose · esc to dismiss · type to continue
            """.components(separatedBy: "\n")
        XCTAssertEqual(PermissionPrompt.read(screen)?.question, "Set up security for Daybreak mode")
    }

    func testReadsGeminiTrustPrompt() {
        let screen = ["│ Do you trust the files in this folder? │", "│ ● 1. Trust folder (agent-play) │",
                      "│   2. Trust parent folder (scratchpad) │", "│   3. Don't trust │"]
        XCTAssertTrue(PermissionPrompt.isVisible(screen))
        XCTAssertEqual(PermissionPrompt.read(screen)?.choices.map(\.key), ["1", "2", "3"])
    }

    func testIgnoresNumberedOutputAboveThePrompt() {
        let screen = ["Plan:", "1. Read", "2. Write", "Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel"]
        XCTAssertEqual(PermissionPrompt.read(screen)?.choices.map(\.label), ["Yes", "No"])
    }

    func testOddNumeralsDontCrash() {
        let screen = ["Proceed?", "½. half", "❯ 1. Yes", "  99999999999999999999. big", "Esc to cancel"]
        XCTAssertEqual(PermissionPrompt.read(screen)?.choices.map(\.key), ["1"])
        XCTAssertNil(PermissionPrompt.read(["Proceed?", "❯ 9223372036854775807. Yes", "1. No"]))
        XCTAssertEqual(PermissionPrompt.read(["Proceed?", "❯ . malformed", "❯ 1. Yes", "Esc to cancel"])?.choices.map(\.key), ["1"])
    }

    func testNilWithoutAPrompt() {
        XCTAssertNil(PermissionPrompt.read(["$ ls", "1. a"]))
    }
}

final class TabInfoTests: XCTestCase {
    func testStatusWireNamesRoundTrip() {
        for status in [TabStatus.idle, .working, .done, .waiting, .exited] {
            XCTAssertEqual(TabStatus(wireName: status.wireName), status)
        }
        XCTAssertEqual(TabStatus.waiting.wireName, "needsYou")
    }

    func testRowDecodesWithoutAgtermFields() throws {
        let json = #"{"id":"t1","title":"Fix","provider":"ClaudeCode","processing":true,"needsApproval":false,"lastActive":"2026-10-25T00:00:00Z","extra":1}"#
        let row = try JSONDecoder().decode(RemoteTabRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.id, "t1")
        XCTAssertNil(row.agterm)
    }
}

final class NewTabOptionsTests: XCTestCase {
    func testFoldersOpenTabsFirstThenProjectsThenHome() {
        let real: Set<String> = ["/u/a", "/u/b", "/u/p", "/u"]
        let folders = NewTabOptions.folders(tabs: ["/u/a", "/u/b", "/u/a"], projects: ["/u/p", "/u/b", "/u/gone"],
                                            home: "/u", exists: real.contains)
        XCTAssertEqual(folders, ["/u/a", "/u/b", "/u/p", "/u"])
    }

    func testFoldersAreCapped() {
        let tabs = (0..<50).map { "/u/\($0)" }
        XCTAssertEqual(NewTabOptions.folders(tabs: tabs, projects: [], home: "/u", limit: 5, exists: { _ in true }).count, 5)
    }

    func testAgentForProvider() {
        XCTAssertEqual(NewTabOptions.command(provider: "claude"), .some("claude"))
        XCTAssertEqual(NewTabOptions.command(provider: AgTermWire.shellProvider), .some(nil))
        XCTAssertNil(NewTabOptions.command(provider: "rm -rf ~"))
    }

    func testOptionsRoundTrip() throws {
        let options = NewTabOptions(agents: [.init(id: "claude", title: "Claude Code")], folders: ["/u/a"], home: "/u")
        XCTAssertEqual(try JSONDecoder().decode(NewTabOptions.self, from: JSONEncoder().encode(options)), options)
    }
}
