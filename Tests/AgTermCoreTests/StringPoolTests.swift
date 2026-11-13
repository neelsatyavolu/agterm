@testable import AgTermCore
import XCTest

final class StringPoolTests: XCTestCase {
    func testReturnsTheFirstCopyOfEqualStrings() {
        var pool = StringPool()
        let first = pool.intern(String(repeating: "claude-opus-", count: 3))
        let second = pool.intern(String(repeating: "claude-opus-", count: 3))
        XCTAssertEqual(first, second)
        XCTAssertTrue(sameStorage(first, second))
    }

    func testKeepsDistinctStringsApart() {
        var pool = StringPool()
        XCTAssertEqual(pool.intern("project-a"), "project-a")
        XCTAssertEqual(pool.intern(Substring("project-b")), "project-b")
    }

    /// Both strings point at the same UTF-8 bytes (long enough not to be stored inline).
    private func sameStorage(_ a: String, _ b: String) -> Bool {
        var a = a, b = b
        let pa = a.withUTF8 { UnsafeRawPointer($0.baseAddress) }
        let pb = b.withUTF8 { UnsafeRawPointer($0.baseAddress) }
        return pa != nil && pa == pb
    }
}
