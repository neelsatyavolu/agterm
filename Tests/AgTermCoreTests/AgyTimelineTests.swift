import XCTest
@testable import AgTermCore

/// Antigravity steps built the way agy 1.5 writes them (field numbers in `AgyTimeline`).
final class AgyTimelineTests: XCTestCase {
    // MARK: A minimal protobuf writer

    enum Field {
        case int(Int, Int)
        case text(Int, String)
        case message(Int, [Field])
    }

    static func encode(_ fields: [Field]) -> Data {
        var out = Data()
        func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            out.append(UInt8(v))
        }
        for field in fields {
            switch field {
            case .int(let number, let value):
                varint(UInt64(number << 3)); varint(UInt64(value))
            case .text(let number, let text):
                let bytes = Data(text.utf8)
                varint(UInt64(number << 3 | 2)); varint(UInt64(bytes.count)); out.append(bytes)
            case .message(let number, let inner):
                let bytes = encode(inner)
                varint(UInt64(number << 3 | 2)); varint(UInt64(bytes.count)); out.append(bytes)
            }
        }
        return out
    }

    static func time(_ seconds: Int, _ nanos: Int = 0) -> [Field] { [.int(1, seconds), .int(2, nanos)] }

    static func step(_ index: Int, type: Int, status: Int = 3, created: Int = 1_000, meta: [Field] = [], _ own: [Field]) -> AgyStep {
        let payload = encode([.int(1, type), .int(4, status), .message(5, [.message(1, time(created))] + meta)] + own)
        return AgyStep(index: index, type: type, status: status, payload: payload)
    }

    static func user(_ index: Int, _ text: String, status: Int = 3) -> AgyStep {
        step(index, type: 14, status: status, [.message(19, [.text(2, text)])])
    }

    static func call(_ id: String, _ name: String, _ args: String) -> [Field] {
        [.text(1, id), .text(2, name), .text(3, args)]
    }

    static func reply(_ index: Int, thinking: String? = nil, text: String? = nil, calls: [[Field]] = [], status: Int = 3) -> AgyStep {
        var reply: [Field] = []
        if let thinking { reply.append(.text(3, thinking)) }
        if let text { reply.append(.text(1, text)); reply.append(.text(8, text)) }
        reply += calls.map { .message(7, $0) }
        return step(index, type: 15, status: status, created: 1_001, [.message(20, reply)])
    }

    static func run(_ index: Int, _ call: [Field], status: Int = 3, output: String? = nil, command: (exit: Int, output: String)? = nil,
                    error: String? = nil) -> AgyStep {
        var result: [Field] = []
        if let output { result.append(.text(1, "Created At: 2026-11-24T15:42:57-07:00\nCompleted At: 2026-11-24T15:42:59-07:00\n" + output)) }
        if let command {
            result.append(.message(3, [.message(10, [.message(3, [.text(1, "cmd"), .int(3, command.exit), .text(4, command.output)])])]))
        }
        var own: [Field] = [.message(140, [.message(2, result)])]
        if let error { own.append(.message(31, [.text(2, error), .text(3, error)])) }
        return step(index, type: 132, status: status, created: 1_002, meta: [.message(4, call), .message(8, time(1_005, 500_000_000))], own)
    }

    // MARK: Tests

    func testUserReplyAndThinking() {
        let entries = AgyTimeline.entries([Self.user(0, "fix the build"), Self.reply(1, thinking: "Looking at it.\n\n", text: "Fixed it.")])
        XCTAssertEqual(entries.map(\.kind), ["user", "thinking", "assistant"])
        XCTAssertEqual(entries[0].text, "fix the build")
        XCTAssertEqual(entries[0].ts, 1_000_000)
        XCTAssertEqual(entries[1].text, "Looking at it.")
        XCTAssertEqual(entries[2].text, "Fixed it.")
    }

    func testQueuedMessage() {
        XCTAssertEqual(AgyTimeline.entries([Self.user(0, "next", status: 11)]).first?.state, "queued")
    }

    func testCallRunsUntilItsStepArrivesThenTakesItsResult() {
        let call = Self.call("c1", "view_file", #"{"AbsolutePath":"/repo/src/main.swift","toolSummary":"View main"}"#)
        let pending = AgyTimeline.entries([Self.reply(1, calls: [call])])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].status, "running")
        XCTAssertEqual(pending[0].lead, "Read")
        XCTAssertEqual(pending[0].subject, "src/main.swift")

        let done = AgyTimeline.entries([Self.reply(1, calls: [call]), Self.run(2, call, output: "1: import Foundation")])
        XCTAssertEqual(done.count, 1, "the run replaces the pending call")
        XCTAssertEqual(done[0].status, "ok")
        XCTAssertEqual(done[0].body, "1: import Foundation", "the Created/Completed header is dropped")
        XCTAssertEqual(done[0].ts, 1_001_000, "keeps when it was asked for")
        XCTAssertEqual(done[0].endTs, 1_005_500)
    }

    func testCommandExitCodeAndOutput() {
        let call = Self.call("c2", "run_command", #"{"CommandLine":"swift test","Cwd":"/repo","toolSummary":"Run tests"}"#)
        let ok = AgyTimeline.entries([Self.run(0, call, command: (0, "All tests passed"))])[0]
        XCTAssertEqual(ok.lead, "Ran")
        XCTAssertEqual(ok.subject, "swift test")
        XCTAssertEqual(ok.status, "ok")
        XCTAssertEqual(ok.body, "All tests passed")
        let failed = AgyTimeline.entries([Self.run(0, call, command: (1, "2 failures"))])[0]
        XCTAssertEqual(failed.status, "error")
        XCTAssertEqual(ChatRows.build([failed], working: false).first?.kindName, "command")
    }

    func testErrorsAndCancels() {
        let call = Self.call("c3", "run_command", #"{"CommandLine":"ls"}"#)
        let denied = AgyTimeline.entries([Self.run(0, call, status: 7, error: "tool call denied by pre-tool hook")])[0]
        XCTAssertEqual(denied.status, "error")
        XCTAssertEqual(denied.body, "tool call denied by pre-tool hook")
        let canceled = AgyTimeline.entries([Self.run(0, call, status: 6)])[0]
        XCTAssertEqual(canceled.status, "error")
        XCTAssertEqual(canceled.body, "Canceled")
        let running = AgyTimeline.entries([Self.run(0, call, status: 2)])[0]
        XCTAssertEqual(running.status, "running")
        XCTAssertNil(running.endTs)
    }

    func testEditsBecomeDiffs() {
        let replace = Self.call("e1", "replace_file_content",
                                #"{"TargetFile":"/repo/a.txt","TargetContent":"original","ReplacementContent":"changed\nmore","toolSummary":"Edit a"}"#)
        let edit = AgyTimeline.entries([Self.run(0, replace, output: "ok")])[0]
        XCTAssertEqual(edit.lead, "Edited")
        XCTAssertEqual(edit.subject, "repo/a.txt")
        XCTAssertEqual(edit.additions, 2)
        XCTAssertEqual(edit.deletions, 1)
        guard case .edit(let card)? = ChatRows.build([edit], working: false).first else { return XCTFail("an edit card") }
        XCTAssertEqual(card.lines.map(\.text), ["original", "changed", "more"])

        let write = Self.call("w1", "write_to_file", #"{"TargetFile":"/repo/new.txt","CodeContent":"hello","Overwrite":"True"}"#)
        let wrote = AgyTimeline.entries([Self.run(0, write, output: "ok")])[0]
        XCTAssertEqual(wrote.lead, "Wrote")
        XCTAssertEqual(wrote.additions, 1)

        let multi = Self.call("m1", "multi_replace_file_content",
                              #"{"TargetFile":"/repo/b.txt","ReplacementChunks":[{"TargetContent":"a","ReplacementContent":"b"},{"TargetContent":"c","ReplacementContent":"d"}]}"#)
        let multiEdit = AgyTimeline.entries([Self.run(0, multi, output: "ok")])[0]
        XCTAssertEqual(multiEdit.additions, 2)
        XCTAssertEqual(multiEdit.deletions, 2)
    }

    func testSearchesAndSubagents() {
        let grep = AgyTimeline.entries([Self.run(0, Self.call("g", "grep_search", #"{"Query":"TODO","SearchPath":"/repo"}"#), output: "3 matches")])[0]
        XCTAssertEqual(grep.lead, "Searched")
        XCTAssertEqual(grep.subject, "TODO")
        let agent = AgyTimeline.entries([Self.run(0, Self.call("s", "invoke_subagent",
            #"{"Subagents":[{"Prompt":"Review the diff","Role":"Reviewer"}],"toolSummary":"Review changes"}"#), output: "Looks good")])[0]
        XCTAssertEqual(agent.lead, "Agent")
        XCTAssertEqual(ChatRows.build([agent], working: false).first?.kindName, "agent")
        let other = AgyTimeline.entries([Self.run(0, Self.call("t", "manage_task", #"{"Action":"status","toolSummary":"Check task"}"#), output: "done")])[0]
        XCTAssertEqual(other.lead, "Manage task")
        XCTAssertEqual(other.subject, "Check task")
    }

    func testMalformedPayloadsAreSkipped() {
        let garbage = AgyStep(index: 0, type: 15, status: 3, payload: Data([0xFF, 0xFF, 0xFF]))
        let truncated = AgyStep(index: 1, type: 14, status: 3, payload: Self.encode([.message(19, [.text(2, "hi")])]).dropLast(1))
        XCTAssertEqual(AgyTimeline.entries([garbage, truncated, Self.user(2, "still read")]).map(\.text), ["still read"])
    }

    func testFeedLoadsSteps() {
        var feed = TimelineFeed(agent: .agy)
        feed.load(agySteps: [Self.user(0, "hi"), Self.reply(1, text: "hello")])
        XCTAssertEqual(feed.entries.map(\.kind), ["user", "assistant"])
    }

    func testSettled() {
        XCTAssertTrue(Self.user(0, "a", status: 3).isSettled)
        XCTAssertTrue(Self.user(0, "a", status: 7).isSettled)
        XCTAssertFalse(Self.user(0, "a", status: 2).isSettled)
        XCTAssertFalse(Self.user(0, "a", status: 8).isSettled)
        XCTAssertFalse(Self.user(0, "a", status: 9).isSettled)
    }
}
