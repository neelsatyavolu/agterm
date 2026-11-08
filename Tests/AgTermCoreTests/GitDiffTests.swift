@testable import AgTermCore
import XCTest

final class GitDiffTests: XCTestCase {
    func testNumstatParsesCountsBinaryAndRenames() {
        // -z: "added\tremoved\tpath\0"; a rename is "added\tremoved\t\0old\0new\0".
        let out = "3\t1\tSources/a.swift\0-\t-\tlogo.png\0" + "2\t0\t\0old/name.swift\0new/name.swift\0"
        let files = GitDiff.parseNumstat(out)
        XCTAssertEqual(files, [
            FileChange(path: "Sources/a.swift", added: 3, removed: 1),
            FileChange(path: "logo.png", binary: true),
            FileChange(path: "new/name.swift", oldPath: "old/name.swift", added: 2, removed: 0),
        ])
    }

    func testNumstatIgnoresEmptyAndMalformedOutput() {
        XCTAssertEqual(GitDiff.parseNumstat(""), [])
        XCTAssertEqual(GitDiff.parseNumstat("garbage\0"), [])
    }

    func testPatchNumbersLinesAndSkipsHeaders() {
        let patch = """
        diff --git a/x.txt b/x.txt
        index 1111111..2222222 100644
        --- a/x.txt
        +++ b/x.txt
        @@ -1,3 +1,3 @@ func main
         one
        -two
        +TWO
         three
        \\ No newline at end of file
        """
        let doc = GitDiff.parsePatch(patch, maxLines: 100)
        XCTAssertEqual(doc.lines, [
            DiffLine(kind: .hunk, text: "@@ -1,3 +1,3 @@ func main"),
            DiffLine(kind: .context, text: "one", old: 1, new: 1),
            DiffLine(kind: .removed, text: "two", old: 2),
            DiffLine(kind: .added, text: "TWO", new: 2),
            DiffLine(kind: .context, text: "three", old: 3, new: 3),
            DiffLine(kind: .note, text: "No newline at end of file"),
        ])
        XCTAssertFalse(doc.truncated)
    }

    func testPatchStopsAtLimit() {
        let body = (1...50).map { "+line \($0)" }.joined(separator: "\n")
        let doc = GitDiff.parsePatch("@@ -0,0 +1,50 @@\n" + body, maxLines: 10)
        XCTAssertEqual(doc.lines.count, 10)
        XCTAssertTrue(doc.truncated)
    }

    func testBinaryPatchSaysSo() {
        let doc = GitDiff.parsePatch("diff --git a/p.png b/p.png\nBinary files a/p.png and b/p.png differ\n", maxLines: 10)
        XCTAssertEqual(doc.lines, [DiffLine(kind: .note, text: "Binary file")])
    }

    func testNewFileIsAllAdded() {
        let doc = GitDiff.newFile("a\nb\n", maxLines: 10)
        XCTAssertEqual(doc.lines, [
            DiffLine(kind: .hunk, text: "New file · 2 lines"),
            DiffLine(kind: .added, text: "a", new: 1),
            DiffLine(kind: .added, text: "b", new: 2),
        ])
    }

    func testArgumentsCompareAgainstBaseAndFollowRenames() {
        XCTAssertEqual(GitDiff.numstatArguments(base: "abc"),
                       ["--no-optional-locks", "diff", "--numstat", "-z", "-M", "--no-ext-diff", "abc"])
        XCTAssertEqual(GitDiff.patchArguments(base: "abc", file: FileChange(path: "n.swift", oldPath: "o.swift")),
                       ["--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "-M", "-U3", "abc", "--", "o.swift", "n.swift"])
    }

    func testUntrackedForAgentScopeAreOnlyNewOnes() {
        XCTAssertEqual(GitDiff.newUntracked(now: ["a", "b", "c"], baseline: ["a"]), ["b", "c"])
        XCTAssertEqual(GitDiff.newUntracked(now: ["a"], baseline: nil), ["a"])
    }

    func testDefaultBranchFromOriginHead() {
        XCTAssertEqual(GitDiff.defaultBranch(originHead: "refs/remotes/origin/develop\n", localBranches: ["main"]), "origin/develop")
        XCTAssertEqual(GitDiff.defaultBranch(originHead: nil, localBranches: ["feature", "master"]), "master")
        XCTAssertEqual(GitDiff.defaultBranch(originHead: nil, localBranches: ["main", "master"]), "main")
        XCTAssertNil(GitDiff.defaultBranch(originHead: nil, localBranches: ["feature"]))
    }
}
