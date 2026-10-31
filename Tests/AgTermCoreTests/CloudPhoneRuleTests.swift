import AgTermCore
import Foundation
import XCTest

final class CloudPhoneRuleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func connect(handoff: Bool = true, tabs: Bool = true, mac: Bool = false, left: TimeInterval = 0,
                         replaced: TimeInterval? = nil, at seconds: TimeInterval) -> Bool {
        CloudPhoneRule.shouldConnect(hasHandoff: handoff, hasTabs: tabs, macConnected: mac,
                                     macLastSeen: start.addingTimeInterval(left),
                                     replacedAt: replaced.map(start.addingTimeInterval), now: start.addingTimeInterval(seconds))
    }

    func testConnectsOnceTheMacHasBeenGoneAWhile() {
        XCTAssertFalse(connect(at: 5))
        XCTAssertTrue(connect(at: CloudPhoneRule.macGoneAfter))
    }

    func testNeverWhileTheMacIsConnected() {
        XCTAssertFalse(connect(mac: true, at: 600))
    }

    func testNeedsTheHandoffAndTabs() {
        XCTAssertFalse(connect(handoff: false, at: 600))
        XCTAssertFalse(connect(tabs: false, at: 600))
    }

    /// The Mac took the relay back: wait until it has come and gone again.
    func testReplacedWaitsForTheMacToLeaveAgain() {
        XCTAssertFalse(connect(left: 0, replaced: 30, at: 600))
        XCTAssertFalse(connect(left: 40, replaced: 30, at: 50))
        XCTAssertTrue(connect(left: 40, replaced: 30, at: 40 + CloudPhoneRule.macGoneAfter))
    }

    func testHandoffRoundTrips() throws {
        let handoff = CloudPhoneHandoff(desktopId: "d", desktopSecret: "s", relay: "wss://r/ws", deviceName: "Mac",
                                        theme: "ink", home: "/Users/me", tabs: [.init(id: "t1", name: nil), .init(id: "t2", name: "api")])
        XCTAssertEqual(try JSONDecoder().decode(CloudPhoneHandoff.self, from: JSONEncoder().encode(handoff)), handoff)
    }
}
