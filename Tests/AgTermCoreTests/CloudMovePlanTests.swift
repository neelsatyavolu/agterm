import XCTest
@testable import AgTermCore

final class CloudMovePlanTests: XCTestCase {
    private let home = "/Users/neel"

    func testCopiesTheRepositoryElseAnAgentsFolder() {
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/Users/neel/code/app/src", gitRoot: "/Users/neel/code/app", hasAgent: false, home: home),
                       "/Users/neel/code/app")
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/Users/neel/notes/", gitRoot: nil, hasAgent: true, home: home), "/Users/neel/notes")
        XCTAssertNil(CloudMovePlan.folder(cwd: "/Users/neel/notes", gitRoot: nil, hasAgent: false, home: home))
    }

    func testNeverCopiesHomeOrAbove() {
        XCTAssertNil(CloudMovePlan.folder(cwd: home, gitRoot: nil, hasAgent: true, home: home))
        XCTAssertNil(CloudMovePlan.folder(cwd: "/Users/neel/", gitRoot: nil, hasAgent: true, home: home))
        XCTAssertNil(CloudMovePlan.folder(cwd: "/x", gitRoot: home, hasAgent: true, home: home))
        XCTAssertNil(CloudMovePlan.folder(cwd: "/Users", gitRoot: nil, hasAgent: true, home: home))
        XCTAssertNil(CloudMovePlan.folder(cwd: "/", gitRoot: nil, hasAgent: true, home: home))
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/tmp/scratch", gitRoot: nil, hasAgent: true, home: home), "/tmp/scratch")
        // A sibling whose name starts like home is not above it.
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/Users/neelx", gitRoot: nil, hasAgent: true, home: home), "/Users/neelx")
    }

    /// The cloud machine gets the very same path: /private/tmp must not become /tmp.
    func testKeepsPathsAsTheyAre() {
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/private/tmp/x", gitRoot: nil, hasAgent: true, home: home), "/private/tmp/x")
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/Users/neel//code/./app/../web/", gitRoot: nil, hasAgent: true, home: home),
                       "/Users/neel/code/web")
    }

    /// Home is a link: the kernel reports the folder by its real path, which must count as home too.
    func testNeverCopiesHomeReachedThroughALink() {
        let real = ["/Users/neel": "/Volumes/Data/neel"]
        let resolve = { (path: String) in real[path] ?? path }
        XCTAssertNil(CloudMovePlan.folder(cwd: "/Volumes/Data/neel", gitRoot: nil, hasAgent: true, home: home, resolve: resolve))
        XCTAssertNil(CloudMovePlan.folder(cwd: "/Volumes/Data", gitRoot: nil, hasAgent: true, home: home, resolve: resolve))
        XCTAssertEqual(CloudMovePlan.folder(cwd: "/Volumes/Data/neel/code", gitRoot: nil, hasAgent: true, home: home, resolve: resolve),
                       "/Volumes/Data/neel/code")
    }

    func testRootsAreUniqueAndOutermost() {
        XCTAssertEqual(CloudMovePlan.roots(["/a/b", "/a", "/a/", "/ab", "/c/d", "/c/d/e/f"]), ["/a", "/ab", "/c/d"])
    }

    func testFindsTheClaudeProjectHoldingTheConversation() {
        let files: Set<String> = ["/Users/neel/.claude/projects/-Users-neel-code-app/abc.jsonl"]
        XCTAssertEqual(CloudMovePlan.claudeProject(sessionID: "abc", home: home, projects: ["-Users-neel", "-Users-neel-code-app"],
                                                   exists: files.contains),
                       "/Users/neel/.claude/projects/-Users-neel-code-app")
        XCTAssertNil(CloudMovePlan.claudeProject(sessionID: "zzz", home: home, projects: ["-Users-neel-code-app"], exists: files.contains))
    }

    func testIgnoreRulesAnchorWhatGitIgnores() {
        let output = [".derived/", ".claude/", "Packages/Core/.build/", ".DS_Store", ".env", "api/.env.local", "logs[1]/", ""].joined(separator: "\0")
        XCTAssertEqual(CloudMovePlan.ignoreRules(gitIgnored: output),
                       ["/.derived/", "/.claude/", "/Packages/Core/.build/", "/.DS_Store", "/.env", "/api/.env.local", "/logs\\[1]/"])
        XCTAssertEqual(CloudMovePlan.ignoreRules(gitIgnored: ""), [])
    }
}
