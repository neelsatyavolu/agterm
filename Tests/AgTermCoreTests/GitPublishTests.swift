@testable import AgTermCore
import XCTest

final class GitPublishTests: XCTestCase {
    func testCommitMessageIsCleaned() {
        XCTAssertEqual(GitPublish.cleanMessage("```\nfix: stop crash\n\nBody line\n```"), "fix: stop crash\n\nBody line")
        XCTAssertEqual(GitPublish.cleanMessage("Commit message: \"feat: add x\""), "feat: add x")
        XCTAssertNil(GitPublish.cleanMessage("  \n "))
    }

    func testPullRequestReplySplitsTitleAndBody() {
        let pr = GitPublish.parsePullRequest("Title: Add diff panel\n\n## Summary\n- one")
        XCTAssertEqual(pr?.title, "Add diff panel")
        XCTAssertEqual(pr?.body, "## Summary\n- one")
        XCTAssertEqual(GitPublish.parsePullRequest("Only a title")?.body, "")
        XCTAssertNil(GitPublish.parsePullRequest(""))
    }

    func testBranchFromCommitSubject() {
        XCTAssertEqual(GitPublish.branchName(forSubject: "fix: Stop the login redirect loop on Safari now"),
                       "agterm/stop-the-login-redirect-loop")
        XCTAssertEqual(GitPublish.branchName(forSubject: "!!!"), "agterm/changes")
    }

    func testParsesUpstreamState() {
        XCTAssertEqual(GitPublish.upstream(statusHeader: "## main...origin/main [ahead 2, behind 1]"),
                       UpstreamState(branch: "main", upstream: "origin/main", ahead: 2, behind: 1))
        XCTAssertEqual(GitPublish.upstream(statusHeader: "## feature"),
                       UpstreamState(branch: "feature", upstream: nil, ahead: 0, behind: 0))
        XCTAssertEqual(GitPublish.upstream(statusHeader: "## HEAD (no branch)"),
                       UpstreamState(branch: nil, upstream: nil, ahead: 0, behind: 0))
    }

    func testParsesPullRequestView() throws {
        let json = #"{"number":42,"url":"https://github.com/o/r/pull/42","state":"OPEN","isDraft":false}"#
        XCTAssertEqual(GitPublish.pullRequest(json: Data(json.utf8)),
                       PullRequest(number: 42, url: "https://github.com/o/r/pull/42", state: "OPEN"))
        XCTAssertNil(GitPublish.pullRequest(json: Data("no".utf8)))
    }

    func testPromptsCarryDiffWithinBudget() {
        let patch = String(repeating: "+x\n", count: 20_000)
        let message = GitPublish.commitRequest(stat: " a.swift | 2 +", patch: patch, recentSubjects: ["feat: a"])
        XCTAssertLessThan(message.count, GitPublish.patchBudget + 1_000)
        XCTAssertTrue(message.contains("feat: a"))
    }
}
