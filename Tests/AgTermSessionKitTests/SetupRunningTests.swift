import AgTermCore
@testable import AgTermSessionKit
import Foundation
import XCTest

/// The cloud machine stays up while a dependency install holds its folder's lock.
final class SetupRunningTests: XCTestCase {
    func testRunningWhileALockIsHeld() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        XCTAssertFalse(SessionHelperMain.setupRunning(in: folder))

        let path = folder + "/123" + CloudSetup.setupLockSuffix
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertFalse(SessionHelperMain.setupRunning(in: folder), "a lock file nobody holds")

        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        XCTAssertTrue(SessionHelperMain.setupRunning(in: folder))
        // The check let go of the lock it tested.
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertFalse(SessionHelperMain.setupRunning(in: folder))
    }
}
