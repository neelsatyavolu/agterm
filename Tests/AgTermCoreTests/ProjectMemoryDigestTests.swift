import XCTest
@testable import AgTermCore

final class ProjectMemoryDigestTests: XCTestCase {
    private func entry(_ title: String, kind: String = "decision", updated: String, content: String = "",
                       archived: Bool = false, status: String = "current", binding: Bool = false, important: Bool = false) -> [String: Any] {
        ["id": UUID().uuidString, "kind": kind, "title": title, "content": content, "createdAt": updated, "updatedAt": updated,
         "archived": archived, "status": status, "binding": binding, "important": important]
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testListsCurrentEntriesBindingFirstThenNewest() throws {
        let memory = try data(["entries": [
            entry("Old fact", kind: "fact", updated: "2026-01-01T00:00:00Z"),
            entry("New decision", updated: "2026-03-01T00:00:00Z", content: "Use zap.sh.\nNot make."),
            entry("Gone", updated: "2026-04-01T00:00:00Z", archived: true),
            entry("Replaced", updated: "2026-04-01T00:00:00Z", status: "superseded"),
            entry("Rule", updated: "2025-01-01T00:00:00Z", binding: true),
        ]])
        let text = try XCTUnwrap(ProjectMemoryDigest.render(memory: memory, handoffs: nil))
        let rule = try XCTUnwrap(text.range(of: "Rule")), new = try XCTUnwrap(text.range(of: "New decision"))
        let old = try XCTUnwrap(text.range(of: "Old fact"))
        XCTAssertLessThan(rule.lowerBound, new.lowerBound)
        XCTAssertLessThan(new.lowerBound, old.lowerBound)
        XCTAssertTrue(text.contains("- [decision] New decision: Use zap.sh. Not make."), text)
        XCTAssertFalse(text.contains("Gone"))
        XCTAssertFalse(text.contains("Replaced"))
    }

    func testRecentHandoffsNewestFirst() throws {
        let handoffs = try data(["sessions": [
            ["id": "a", "title": "Older", "summary": "did a", "updatedAt": "2026-02-01T10:00:00Z"],
            ["id": "b", "title": "Newer", "summary": "did b", "updatedAt": "2026-02-03T10:00:00Z"],
        ]])
        let text = try XCTUnwrap(ProjectMemoryDigest.render(memory: nil, handoffs: handoffs))
        XCTAssertTrue(text.contains("- 2026-02-03 Newer: did b"), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Newer")).lowerBound, try XCTUnwrap(text.range(of: "Older")).lowerBound)
    }

    func testCapsALargeStoreAndSaysWhatWasLeftOut() throws {
        let entries = (0..<300).map { entry("Entry \($0)", updated: String(format: "2026-01-01T00:%02d:%02dZ", $0 / 60, $0 % 60),
                                             content: String(repeating: "x", count: 500)) }
        let text = try XCTUnwrap(ProjectMemoryDigest.render(memory: try data(["entries": entries]), handoffs: nil))
        XCTAssertLessThanOrEqual(text.count, ProjectMemoryDigest.maxCharacters + 200)
        XCTAssertTrue(text.contains("Entry 299"), "newest kept")
        XCTAssertTrue(text.contains("more entries"), text)
    }

    func testNilWithNothingSavedOrUnreadableStores() {
        XCTAssertNil(ProjectMemoryDigest.render(memory: nil, handoffs: nil))
        XCTAssertNil(ProjectMemoryDigest.render(memory: Data("not json".utf8), handoffs: Data("{}".utf8)))
    }
}
