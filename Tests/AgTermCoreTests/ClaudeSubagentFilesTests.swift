import AgTermCore
import XCTest

final class ClaudeSubagentFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url)
    }

    func testListsSubagentsAndWorkflowAgents() throws {
        try touch("s1.jsonl")
        try touch("s1/subagents/agent-a.jsonl")
        try touch("s1/subagents/agent-a.meta.json")
        try touch("s1/subagents/workflows/wf_1/agent-b.jsonl")
        try touch("s1/subagents/workflows/wf_1/agent-b.meta.json")
        try touch("s1/tool-results/big.jsonl")
        try touch("s2/subagents/agent-other.jsonl")

        let files = ClaudeTranscript.subagentFiles(of: root.appendingPathComponent("s1.jsonl"))
        XCTAssertEqual(files.map { $0.path.components(separatedBy: "/s1/").last.map { "s1/" + $0 } ?? $0.path },
                       ["s1/subagents/agent-a.jsonl", "s1/subagents/workflows/wf_1/agent-b.jsonl"])
    }

    func testNoSubagentFolder() throws {
        try touch("s1.jsonl")
        XCTAssertEqual(ClaudeTranscript.subagentFiles(of: root.appendingPathComponent("s1.jsonl")), [])
    }

    func testSubagentRowsCountOnceAfterReconcile() {
        let line = #"{"type":"assistant","timestamp":"2026-11-09T10:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5}}}"#
        let other = #"{"type":"assistant","timestamp":"2026-11-09T10:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-haiku-5-5","usage":{"input_tokens":7,"output_tokens":3}}}"#
        let parent = ClaudeTranscript.parse(lines: line, sessionID: "s1", fallbackDir: "p")
        let child = ClaudeTranscript.parse(lines: line + "\n" + other, sessionID: "s1", fallbackDir: "p/s1/subagents/workflows/wf_1")
        let kept = ClaudeTranscript.reconcile(parent + child)
        XCTAssertEqual(kept.map { $0.tokensIn + $0.tokensOut }.reduce(0, +), 25)
        XCTAssertTrue(child.allSatisfy(\.isSubagentPath))
    }
}
