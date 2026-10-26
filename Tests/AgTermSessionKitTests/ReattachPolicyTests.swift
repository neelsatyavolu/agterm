@testable import AgTermSessionKit
import Foundation
import XCTest

final class ReattachPolicyTests: XCTestCase {
    func testSupersededNeverReattaches() {
        var policy = ReattachPolicy()
        XCTAssertNil(policy.delay(after: .superseded))
    }

    func testDroppedRetriesThreeTimesWithBackoffThenGivesUp() {
        let start = Date()
        var policy = ReattachPolicy(now: start)
        XCTAssertEqual(policy.delay(after: .dropped, now: start), 0.2)
        XCTAssertEqual(policy.delay(after: .dropped, now: start), 0.5)
        XCTAssertEqual(policy.delay(after: .dropped, now: start), 1)
        XCTAssertNil(policy.delay(after: .dropped, now: start))
    }

    /// A helper that accepts the reattach and drops it again at once still runs out of tries.
    func testQuickDropsAfterReattachingCountTowardTheCap() {
        let start = Date()
        var policy = ReattachPolicy(now: start)
        for attempt in 0..<3 {
            let now = start.addingTimeInterval(Double(attempt))
            XCTAssertNotNil(policy.delay(after: .dropped, now: now))
            policy.connected(now: now)
        }
        XCTAssertNil(policy.delay(after: .dropped, now: start.addingTimeInterval(3)))
    }

    /// Failed tries long after the last good connection still run out.
    func testFailedTriesAfterALongConnectionStillGiveUp() {
        let start = Date()
        var policy = ReattachPolicy(now: start)
        let later = start.addingTimeInterval(ReattachPolicy.stableAfter * 5)
        for attempt in 0..<3 { XCTAssertNotNil(policy.delay(after: .dropped, now: later.addingTimeInterval(Double(attempt) * 20))) }
        XCTAssertNil(policy.delay(after: .dropped, now: later.addingTimeInterval(100)))
    }

    func testConnectionThatStaysUpResetsTheCount() {
        let start = Date()
        var policy = ReattachPolicy(now: start)
        for _ in 0..<3 { _ = policy.delay(after: .dropped, now: start) }
        policy.connected(now: start)
        let later = start.addingTimeInterval(ReattachPolicy.stableAfter + 1)
        XCTAssertEqual(policy.delay(after: .dropped, now: later), 0.2)
    }
}
