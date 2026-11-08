import XCTest
@testable import AgTermCore

/// Markdown in agent replies → the chat's lines, and what the composer types.
final class ChatTextTests: XCTestCase {
    func testPlainReplyIsOneTextLine() {
        XCTAssertEqual(ChatText.lines("Builds clean."), [.text([ChatSpan(.plain, "Builds clean.")])])
    }

    func testHeadingsListsAndInlineStyles() {
        let lines = ChatText.lines("""
            ## Plan

            - read **Theme.swift**
              - then `TabCardDrawing`
            2. build
            > quoted
            """)
        XCTAssertEqual(lines, [
            .heading([ChatSpan(.plain, "Plan")]),
            .blank,
            .bullet(indent: 0, marker: "•", [ChatSpan(.plain, "read "), ChatSpan(.bold, "Theme.swift")]),
            .bullet(indent: 1, marker: "•", [ChatSpan(.plain, "then "), ChatSpan(.code, "TabCardDrawing")]),
            .bullet(indent: 0, marker: "2.", [ChatSpan(.plain, "build")]),
            .quote([ChatSpan(.plain, "quoted")]),
        ])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(ChatText.lines("#hashtag"), [.text([ChatSpan(.plain, "#hashtag")])])
    }

    func testCodeFencesKeepTheirLinesVerbatim() {
        let lines = ChatText.lines("Run:\n```sh\nswift build\n  - not a bullet\n```\nDone.")
        XCTAssertEqual(lines, [.text([ChatSpan(.plain, "Run:")]), .code(["swift build", "  - not a bullet"]),
                               .text([ChatSpan(.plain, "Done.")])])
    }

    func testNestedFencesCloseOnlyOnTheirOwnMark() {
        let lines = ChatText.lines("~~~~md\n```swift\nlet x = 1\n```\n~~~~\nafter")
        XCTAssertEqual(lines, [.code(["```swift", "let x = 1", "```"]), .text([ChatSpan(.plain, "after")])])
        // A longer backtick fence holds a shorter one.
        XCTAssertEqual(ChatText.lines("````\n```\nx\n```\n````"), [.code(["```", "x", "```"])])
    }

    func testUnclosedFenceWhileStreamingShowsAsCode() {
        XCTAssertEqual(ChatText.lines("Here:\n```\nlet a"), [.text([ChatSpan(.plain, "Here:")]), .code(["let a"])])
    }

    func testTablesBecomeAlignedRows() {
        let lines = ChatText.lines("| a | long |\n|---|---|\n| xyz | 1 |")
        XCTAssertEqual(lines, [.tableRow("a    long", header: true), .tableRow("xyz  1", header: false)])
    }

    func testUnclosedInlineMarksStayPlain() {
        XCTAssertEqual(ChatText.spans("a `b and **c"), [ChatSpan(.plain, "a `b and **c")])
        XCTAssertEqual(ChatText.spans("****"), [ChatSpan(.plain, "****")])
    }

    func testUnicodeAndLongWordsPassThrough() {
        let text = "完了 ✅ שלום e\u{301} " + String(repeating: "x", count: 5000)
        XCTAssertEqual(ChatText.lines(text), [.text([ChatSpan(.plain, text)])])
    }

    func testEmptyReplyHasNoLines() {
        XCTAssertEqual(ChatText.lines(""), [])
        XCTAssertEqual(ChatText.lines("\n\n"), [])
    }

    // MARK: Composer

    func testOneLineMessageClearsTheLineFirst() {
        XCTAssertEqual(ChatInput.typing("  fix it \n", bracketedPaste: false), "\u{15}fix it")
        XCTAssertNil(ChatInput.typing(" \n ", bracketedPaste: true))
    }

    func testSeveralLinesGoAsOnePaste() {
        XCTAssertEqual(ChatInput.typing("a\nb", bracketedPaste: true), "\u{15}\u{1b}[200~a\nb\u{1b}[201~")
        XCTAssertEqual(ChatInput.typing("a\r\n\n b", bracketedPaste: false), "\u{15}a b")
    }

    func testInterruptKeyPerAgent() {
        XCTAssertEqual(ChatInput.interrupt(agent: "claude"), "\u{1b}")
        XCTAssertEqual(ChatInput.interrupt(agent: "codex"), "\u{1b}")
        XCTAssertEqual(ChatInput.interrupt(agent: "grok"), "\u{3}")
    }

    func testApprovalKeys() {
        XCTAssertTrue(ChatInput.isApprovalKey("1"))
        XCTAssertTrue(ChatInput.isApprovalKey("y"))
        XCTAssertFalse(ChatInput.isApprovalKey("0"))
        XCTAssertFalse(ChatInput.isApprovalKey("hello"))
    }

    func testModeHintFromClaudeFooter() {
        XCTAssertEqual(ChatModeHint.read(["> ", "  ⏵⏵ accept edits on (shift+tab to cycle)"]), "accept edits on")
        XCTAssertEqual(ChatModeHint.read(["  ⏸ plan mode on (shift+tab to cycle)", ""]), "plan mode on")
        XCTAssertNil(ChatModeHint.read(["> ", "  ? for shortcuts"]))
        XCTAssertNil(ChatModeHint.read([]))
    }
}

/// The approval card's context lines, from recorded prompt screens.
final class ChatPromptTests: XCTestCase {
    func testClaudeBashPromptContext() {
        let screen = [
            "  some earlier output",
            "────────────────────────────────────────",
            " Bash command",
            "",
            "   swift build",
            "   Build the project",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No",
            "",
            " Esc to cancel · Tab to amend",
        ]
        let info = PermissionPrompt.read(screen)
        XCTAssertEqual(info?.question, "Do you want to proceed?")
        XCTAssertEqual(info?.choices.map(\.key), ["1", "2"])
        XCTAssertEqual(ChatPrompt.context(screen: screen, question: info?.question), ["Bash command", "swift build", "Build the project"])
    }

    func testBoxedPromptContextStopsAtTheBorder() {
        let screen = [
            "╭──────────────────────────╮",
            "│ Edit file                │",
            "│   Sources/a.swift        │",
            "│ Do you want to make this edit? │",
            "│ ❯ 1. Yes                 │",
            "│   2. No                  │",
            "╰──────────────────────────╯",
            "Esc to cancel",
        ]
        let info = PermissionPrompt.read(screen)
        XCTAssertNotNil(info)
        XCTAssertEqual(ChatPrompt.context(screen: screen, question: info?.question), ["Edit file", "Sources/a.swift"])
    }

    func testCodexPromptShape() {
        let screen = [
            "  Would you like to run the following command?",
            "",
            "  $ npm test",
            "",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for this command (a)",
            "  3. No, and tell Codex what to do differently (esc)",
            "",
            "  Press enter to confirm or esc to cancel",
        ]
        let info = PermissionPrompt.read(screen)
        XCTAssertEqual(info?.choices.count, 3)
        XCTAssertEqual(info?.question, "Would you like to run the following command?")
        // Codex puts the command between the question and the choices.
        XCTAssertEqual(ChatPrompt.context(screen: screen, question: info?.question), ["$ npm test"])
    }

    func testPickerWithoutNumbersIsNotAPrompt() {
        // A menu the chat can't read: it shows the screen excerpt instead.
        let screen = ["Select model", "❯ Default (recommended)", "  Opus", "  Sonnet", "Enter to confirm · Esc to exit"]
        XCTAssertNil(PermissionPrompt.read(screen))
        XCTAssertEqual(ChatRows.screenExcerpt(screen + ["", "  "]), screen)
    }

    func testNoQuestionNoContext() {
        XCTAssertEqual(ChatPrompt.context(screen: ["a"], question: nil), [])
        XCTAssertEqual(ChatPrompt.context(screen: ["a"], question: "missing?"), [])
    }
}
