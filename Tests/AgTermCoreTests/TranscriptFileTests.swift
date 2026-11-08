@testable import AgTermCore
import XCTest

final class TranscriptFileTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ text: String) throws { try Data(text.utf8).write(to: url) }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testReadsCompleteLinesAndStopsBeforeAPartialOne() throws {
        try write("a\r\nbb\nccc")
        var lines: [String] = []
        let end = TranscriptFile.read(url.path, from: 0) { lines.append($0) }
        XCTAssertEqual(lines, ["a", "bb"])
        XCTAssertEqual(end, 6)
    }

    func testResumesFromTheOffsetAfterAnAppend() throws {
        try write("one\ntw")
        var lines: [String] = []
        let first = try XCTUnwrap(TranscriptFile.read(url.path, from: 0) { lines.append($0) })
        try append("o\nthree\n")
        let second = TranscriptFile.read(url.path, from: first) { lines.append($0) }
        XCTAssertEqual(lines, ["one", "two", "three"])
        XCTAssertEqual(second, 14)
    }

    func testLinesLongerThanTheChunkSizeArriveWhole() throws {
        let long = String(repeating: "x", count: 50)
        try write("\(long)\nshort\n\(long)y\n")
        var lines: [String] = []
        let end = TranscriptFile.read(url.path, from: 0, chunkSize: 8) { lines.append($0) }
        XCTAssertEqual(lines, [long, "short", long + "y"])
        XCTAssertEqual(end, UInt64(long.count * 2 + 9))
    }

    func testMissingFileIsNil() {
        XCTAssertNil(TranscriptFile.read(url.path, from: 0) { _ in })
    }

    func testTitleScannerMatchesAWholeFileParse() {
        let lines = [
            #"{"type":"last-prompt","lastPrompt":"/review fix the tests\nmore"}"#,
            #"{"type":"assistant","message":{}}"#,
            #"{"type":"ai-title","aiTitle":"Fix flaky tests"}"#,
            #"{"type":"ai-title","aiTitle":"Fix flaky login tests"}"#,
        ]
        var scanner = ClaudeSessionTitle.Scanner()
        XCTAssertNil(scanner.title)
        scanner.feed(lines[0])
        XCTAssertEqual(scanner.title, "fix the tests")
        lines.dropFirst().forEach { scanner.feed($0) }
        XCTAssertEqual(scanner.title, "Fix flaky login tests")
        XCTAssertEqual(scanner.title, ClaudeSessionTitle.parse(lines: lines.joined(separator: "\n")))
    }
}
