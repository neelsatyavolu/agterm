import XCTest
@testable import AgTermCore

/// File changes read out of shell commands (heredoc writes, scripted replaces).
final class ShellEditsTests: XCTestCase {
    func testHeredocWrite() throws {
        let edits = ShellEdits.parse("mkdir -p notes && cat > notes/a.md <<'EOF'\n# Title\n\nbody\nEOF\necho done")
        XCTAssertEqual(edits.count, 1)
        let edit = try XCTUnwrap(edits.first)
        XCTAssertEqual(edit.verb, "Write")
        XCTAssertEqual(edit.path, "notes/a.md")
        XCTAssertEqual(edit.lines, ["# Title", "", "body"].map { ChatDiffLine(kind: .added, text: $0) })
        XCTAssertEqual(edit.additions, 3)
        XCTAssertEqual(edit.deletions, 0)
    }

    func testAppendQuotedPathAndOtherSpellings() {
        XCTAssertEqual(ShellEdits.parse("cat >> \"/tmp/my notes.md\" <<EOF\nline\nEOF").map { [$0.verb, $0.path] }, [["Append", "/tmp/my notes.md"]])
        XCTAssertEqual(ShellEdits.parse("cat <<'X' > out.txt\na\nX").map { [$0.verb, $0.path] }, [["Write", "out.txt"]])
        XCTAssertEqual(ShellEdits.parse("tee -a log.txt <<EOF\na\nEOF").map { [$0.verb, $0.path] }, [["Append", "log.txt"]])
        XCTAssertEqual(ShellEdits.parse("L=/tmp/x; cat > $L/live.js <<'JS'\nlet a = 1\nJS\nnode $L/live.js").map(\.path), ["$L/live.js"])
    }

    func testSeveralHeredocsInOneCommand() {
        let edits = ShellEdits.parse("cat > a.txt <<'EOF'\none\nEOF\ncat > b.txt <<'EOF'\ntwo\nthree\nEOF")
        XCTAssertEqual(edits.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(edits.map(\.additions), [1, 2])
    }

    func testNotAnEdit() {
        XCTAssertEqual(ShellEdits.parse("swift build"), [])
        XCTAssertEqual(ShellEdits.parse("cat <<'EOF'\njust printed\nEOF"), [])
        XCTAssertEqual(ShellEdits.parse("grep -c x <<< \"$text\" > count.txt"), [])
        XCTAssertEqual(ShellEdits.parse("cat > a.txt <<'EOF'\nnever closed"), [])
        XCTAssertEqual(ShellEdits.parse("python3 - <<'EOF'\nprint('a'.replace('a', 'b') if False else 1)\nprint(open('x').read())\nEOF").map(\.path), ["x"],
                       "a literal replace reads as an edit of the file the script names")
        XCTAssertEqual(ShellEdits.parse("python3 - <<'EOF'\nimport json\nprint(json.dumps({}))\nEOF"), [])
    }

    func testPythonReplaceWithLiterals() throws {
        let command = """
        cd /r && python3 - <<'EOF'
        from pathlib import Path
        p = Path("tools/cli.py")
        t = p.read_text()
        t = t.replace('''import json
        import sys
        ''', '''import json
        import os
        import sys
        ''')
        t = t.replace("old_name(", 'new_name(', 1)
        p.write_text(t)
        EOF
        """
        let edit = try XCTUnwrap(ShellEdits.parse(command).first)
        XCTAssertEqual(edit.verb, "Edit")
        XCTAssertEqual(edit.path, "tools/cli.py")
        XCTAssertEqual(edit.lines, [
            ChatDiffLine(kind: .context, text: "import json"),
            ChatDiffLine(kind: .added, text: "import os"),
            ChatDiffLine(kind: .context, text: "import sys"),
            ChatDiffLine(kind: .removed, text: "old_name("),
            ChatDiffLine(kind: .added, text: "new_name("),
        ])
        XCTAssertEqual(edit.additions, 2)
        XCTAssertEqual(edit.deletions, 1)
    }

    func testPythonReplaceWithNamesAndOpen() throws {
        let command = """
        python3 - <<'PY'
        p='src/a.swift'; s=open(p).read()
        old = "let a = 1\\n"
        new = "let a = 2\\n"
        assert old in s
        s = s.replace(old, new)
        open(p,'w').write(s)
        PY
        """
        let edit = try XCTUnwrap(ShellEdits.parse(command).first)
        XCTAssertEqual(edit.path, "src/a.swift")
        XCTAssertEqual(edit.lines, [ChatDiffLine(kind: .removed, text: "let a = 1"), ChatDiffLine(kind: .added, text: "let a = 2")])
    }

    func testPythonEditsOfTwoFilesAndUnreadableCalls() {
        let command = """
        python3 - <<'EOF'
        from pathlib import Path
        a = Path("a.py"); t = a.read_text(); a.write_text(t.replace("x = 1", "x = 2"))
        b = Path("b.py"); t = b.read_text()
        old = t[t.index("def f"):]
        b.write_text(t.replace(old, "def f(): pass\\n").replace("y = 1", "y = 2"))
        EOF
        """
        let edits = ShellEdits.parse(command)
        XCTAssertEqual(edits.map(\.path), ["a.py", "b.py"])
        XCTAssertEqual(edits.last?.lines, [ChatDiffLine(kind: .removed, text: "y = 1"), ChatDiffLine(kind: .added, text: "y = 2")],
                       "a replace whose old text is computed is left out")
    }

    func testPythonStrings() {
        XCTAssertEqual(ShellEdits.pythonString(#"'a\'b\n'"#), "a'b\n")
        XCTAssertEqual(ShellEdits.pythonString(#"r"a\nb""#), #"a\nb"#)
        XCTAssertEqual(ShellEdits.pythonString("'''two\nlines'''"), "two\nlines")
        XCTAssertEqual(ShellEdits.pythonString(#""\d+ \\ end""#), #"\d+ \ end"#)
    }

    func testLongWritesKeepTheirCountButNotEveryLine() throws {
        let body = (1...1_000).map { "line \($0)" }.joined(separator: "\n")
        let edit = try XCTUnwrap(ShellEdits.parse("cat > big.txt <<'EOF'\n\(body)\nEOF").first)
        XCTAssertEqual(edit.additions, 1_000)
        XCTAssertEqual(edit.lines.count, ShellEdits.maxLines)
    }
}
