@testable import AgTermCore
import XCTest

final class FileMentionTests: XCTestCase {
    func testQueryIsTheAtWordAtTheCaret() {
        let text = "look at @Sources/ma please"
        let caret = ("look at @Sources/ma" as NSString).length
        XCTAssertEqual(FileMention.query(text, caret: caret)?.query, "Sources/ma")
        XCTAssertEqual(FileMention.query(text, caret: caret)?.start, 8)
        XCTAssertEqual(FileMention.query("@", caret: 1)?.query, "")
        XCTAssertNil(FileMention.query("mail me@home", caret: 12))
        XCTAssertNil(FileMention.query("look at @x please", caret: 17))
        XCTAssertNil(FileMention.query("@x", caret: 9))
    }

    func testCompletion() {
        XCTAssertEqual(FileMention.completion("Sources/main.swift"), "@Sources/main.swift ")
        XCTAssertEqual(FileMention.completion("Sources/"), "@Sources/")
        XCTAssertEqual(FileMention.completion("My Notes/a.md"), "@\"My Notes/a.md\" ")
    }

    func testMatchesPreferFileNames() {
        let paths = ["Sources/", "Sources/AgTerm/", "README.md", "Sources/AgTerm/Chat/ChatComposer.swift",
                     "Sources/AgTerm/Chat/ChatPaneView.swift", "docs/composer-notes.md"]
        XCTAssertEqual(FileMention.matches("ChatCo", in: paths).first, "Sources/AgTerm/Chat/ChatComposer.swift")
        XCTAssertEqual(FileMention.matches("composer", in: paths).first, "docs/composer-notes.md")
        XCTAssertTrue(FileMention.matches("cpv", in: paths).contains("Sources/AgTerm/Chat/ChatPaneView.swift"))
        XCTAssertTrue(FileMention.matches("zzz", in: paths).isEmpty)
        // An empty query starts with the top level.
        XCTAssertEqual(Array(FileMention.matches("", in: paths).prefix(2)), ["Sources/", "README.md"])
    }

    func testFilesOutsideGitSkipHiddenAndBuildFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["a.txt", "src/b.swift", ".hidden/c", "node_modules/x/d.js", ".env"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        XCTAssertEqual(FileMention.files(in: root.path), ["src/", "a.txt", "src/b.swift"])
        XCTAssertEqual(FileMention.files(in: root.appendingPathComponent("missing").path), [])
    }

    func testFilesInGitFollowGitignore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mention-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["kept.swift", "ignored.log", "sub/new file.md"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "init", "-q", root.path]
        try git.run()
        git.waitUntilExit()
        try XCTSkipUnless(git.terminationStatus == 0, "no git")
        XCTAssertEqual(Set(FileMention.files(in: root.path)), ["sub/", ".gitignore", "kept.swift", "sub/new file.md"])
    }

    func testTypingWithImagesAndATrailingMention() {
        let paste = { (text: String) in "\u{1b}[200~" + text + "\u{1b}[201~" }
        XCTAssertEqual(ChatInput.typing("what is this", images: ["/t/a.png"], bracketedPaste: true),
                       "\u{15}" + paste("/t/a.png") + "what is this")
        XCTAssertEqual(ChatInput.typing("", images: ["/t/a.png", "/t/b.png"], bracketedPaste: true),
                       "\u{15}" + paste("/t/a.png") + paste("/t/b.png"))
        XCTAssertEqual(ChatInput.typing("see", images: ["/t/a.png"], bracketedPaste: false), "\u{15}/t/a.png see")
        XCTAssertEqual(ChatInput.typing("explain @main.swift", bracketedPaste: false), "\u{15}explain @main.swift ")
        XCTAssertEqual(ChatInput.typing("a\nread @x", bracketedPaste: true), "\u{15}" + paste("a\nread @x "))
        XCTAssertEqual(ChatInput.typing("mail me@home.com", bracketedPaste: false), "\u{15}mail me@home.com")
    }
}
