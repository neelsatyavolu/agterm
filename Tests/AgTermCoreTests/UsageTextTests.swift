import AgTermCore
import XCTest

final class UsageTextTests: XCTestCase {
    func testCost() {
        XCTAssertNil(UsageText.cost(0, incomplete: false))
        XCTAssertNil(UsageText.cost(.nan, incomplete: false))
        XCTAssertEqual(UsageText.cost(1.236, incomplete: false), "$1.24")
        XCTAssertEqual(UsageText.cost(0.4, incomplete: true), "$0.40+")
    }

    func testTokens() {
        XCTAssertNil(UsageText.tokens(0))
        XCTAssertEqual(UsageText.tokens(940), "940 tokens")
        XCTAssertEqual(UsageText.tokens(38_400), "38k tokens")
        XCTAssertEqual(UsageText.tokens(1_240_000), "1.2M tokens")
    }

    func testElapsed() {
        XCTAssertEqual(UsageText.elapsed(20), "<1m")
        XCTAssertEqual(UsageText.elapsed(12 * 60 + 5), "12m")
        XCTAssertEqual(UsageText.elapsed(125 * 60), "2h 5m")
        XCTAssertEqual(UsageText.elapsed(120 * 60), "2h")
    }
}
