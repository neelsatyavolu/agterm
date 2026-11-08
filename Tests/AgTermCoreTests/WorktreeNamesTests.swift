@testable import AgTermCore
import XCTest

final class WorktreeNamesTests: XCTestCase {
    func testBranchNamesAreCleanedForGit() {
        XCTAssertEqual(WorktreeNames.branch("  Fix Login Redirect!! "), "fix-login-redirect")
        XCTAssertEqual(WorktreeNames.branch("feat/New thing"), "feat/new-thing")
        XCTAssertEqual(WorktreeNames.branch("a..b//c.lock"), "a.b/c")
        XCTAssertEqual(WorktreeNames.branch("-/-"), "")
        XCTAssertEqual(WorktreeNames.branch(String(repeating: "x", count: 100)).count, 60)
    }

    func testSuggestedNameIsStableForSeed() {
        let name = WorktreeNames.suggested(seed: 7)
        XCTAssertEqual(name, WorktreeNames.suggested(seed: 7))
        XCTAssertTrue(name.hasPrefix("agterm/"))
        XCTAssertEqual(WorktreeNames.branch(name), name)
    }

    func testFolderLivesUnderAgtermWorktrees() {
        XCTAssertEqual(WorktreeNames.folder(home: "/Users/me", repo: "/code/My App", branch: "agterm/quiet-fox"),
                       "/Users/me/.agterm/worktrees/My App/agterm-quiet-fox")
        XCTAssertTrue(WorktreeNames.isManaged("/Users/me/.agterm/worktrees/x/y", home: "/Users/me"))
        XCTAssertFalse(WorktreeNames.isManaged("/Users/me/code/x", home: "/Users/me"))
    }

    func testParsesWorktreeList() {
        let out = """
        worktree /code/app
        HEAD 1111
        branch refs/heads/main

        worktree /Users/me/.agterm/worktrees/app/agterm-quiet-fox
        HEAD 2222
        branch refs/heads/agterm/quiet-fox

        worktree /tmp/detached
        HEAD 3333
        detached
        prunable gitdir file points to non-existent location

        """
        XCTAssertEqual(WorktreeNames.parseList(out), [
            WorktreeEntry(path: "/code/app", branch: "main", isMain: true),
            WorktreeEntry(path: "/Users/me/.agterm/worktrees/app/agterm-quiet-fox", branch: "agterm/quiet-fox"),
            WorktreeEntry(path: "/tmp/detached", branch: nil, prunable: true),
        ])
    }

    func testEnvFilesToCopy() {
        let ignored = [".env", ".env.local", "apps/web/.env.development", "node_modules/x/.env", ".envrc",
                       "build/", "a/b/c/d/.env", ".env.example"]
        XCTAssertEqual(WorktreeNames.envFiles(ignored), [".env", ".env.example", ".env.local", ".envrc", "apps/web/.env.development"])
    }
}
