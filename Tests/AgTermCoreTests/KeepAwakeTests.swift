import XCTest
@testable import AgTermCore

final class KeepAwakePlanTests: XCTestCase {
    private func inputs(enabled: Bool = true, closedLid: Bool = false, helper: Bool = false,
                        busy: Bool = true, battery: Bool = false) -> KeepAwakePlan.Inputs {
        KeepAwakePlan.Inputs(enabled: enabled, closedLid: closedLid, helperInstalled: helper, agentsBusy: busy, onBattery: battery)
    }

    func testHoldsOnlyWhileAgentsAreBusy() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(busy: false)), [])
        XCTAssertEqual(plan.update(inputs(busy: true)), [.holdIdleSleep])
        XCTAssertEqual(plan.update(inputs(busy: true)), [], "no repeat while still busy")
        XCTAssertEqual(plan.update(inputs(busy: false)), [.releaseIdleSleep])
        XCTAssertFalse(plan.holdingIdle)
    }

    func testOffHoldsNothing() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(enabled: false, closedLid: true, helper: true)), [])
        _ = plan.update(inputs())
        XCTAssertEqual(plan.update(inputs(enabled: false)), [.releaseIdleSleep])
    }

    func testClosedLidNeedsTheHelper() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: false)), [.holdIdleSleep])
        XCTAssertFalse(plan.holdingLid)
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true)), [.holdLidSleep])
        XCTAssertEqual(plan.update(inputs(closedLid: false, helper: true)), [.releaseLidSleep])
        XCTAssertTrue(plan.holdingIdle)
    }

    func testIdleReleasesLidFirst() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true)), [.holdIdleSleep, .holdLidSleep])
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, busy: false)), [.releaseLidSleep, .releaseIdleSleep])
    }

    func testWarnsOncePerLidHoldOnBattery() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true)), [.holdIdleSleep, .holdLidSleep])
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: true)), [.warnBattery])
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: true)), [])
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: false)), [])
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: true)), [], "same hold")
        _ = plan.update(inputs(closedLid: true, helper: true, busy: false))
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: true)),
                       [.holdIdleSleep, .holdLidSleep, .warnBattery])
    }

    func testNoBatteryWarningWithoutTheLidHold() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(battery: true)), [.holdIdleSleep])
    }

    func testRestartsAHelperThatStoppedWithoutWarningAgain() {
        var plan = KeepAwakePlan()
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: true)), [.holdIdleSleep, .holdLidSleep, .warnBattery])
        plan.lidHoldEnded()
        XCTAssertFalse(plan.holdingLid)
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: false, battery: true)), [], "waiting to retry")
        XCTAssertEqual(plan.update(inputs(closedLid: true, helper: true, battery: true)), [.holdLidSleep])
    }

    func testReleaseAll() {
        var plan = KeepAwakePlan()
        _ = plan.update(inputs(closedLid: true, helper: true))
        XCTAssertEqual(plan.releaseAll(), [.releaseLidSleep, .releaseIdleSleep])
        XCTAssertEqual(plan.releaseAll(), [])
    }
}

final class ClosedLidHelperTests: XCTestCase {
    func testUserNames() {
        XCTAssertTrue(ClosedLidHelper.isValidUser("neel"))
        XCTAssertTrue(ClosedLidHelper.isValidUser("first.last-2"))
        XCTAssertFalse(ClosedLidHelper.isValidUser("root"))
        XCTAssertFalse(ClosedLidHelper.isValidUser(""))
        XCTAssertFalse(ClosedLidHelper.isValidUser("bob ALL=(ALL) ALL"))
        XCTAssertFalse(ClosedLidHelper.isValidUser("bob\nALL"))
        XCTAssertFalse(ClosedLidHelper.isValidUser("-bob"))
        XCTAssertFalse(ClosedLidHelper.isValidUser("a'b"))
        XCTAssertNil(ClosedLidHelper.sudoers(user: "root"))
        XCTAssertNil(ClosedLidHelper.installScript(user: "x; rm -rf /"))
    }

    func testSudoersAllowsOnlyTheHelperWithItsArguments() throws {
        let rules = try XCTUnwrap(ClosedLidHelper.sudoers(user: "neel"))
        let rule = try XCTUnwrap(rules.split(separator: "\n").first { !$0.hasPrefix("#") })
        let path = ClosedLidHelper.path
        XCTAssertEqual(String(rule), "neel ALL=(root) NOPASSWD: \(path) enable-until *, \(path) disable, \(path) status")
        XCTAssertFalse(ClosedLidHelper.sudoersPath.split(separator: "/").last!.contains("."), "sudo ignores names with dots")
    }

    func testInstallScriptCarriesBothFilesAndChecksSudoers() throws {
        let install = try XCTUnwrap(ClosedLidHelper.installScript(user: "neel"))
        XCTAssertTrue(install.contains(Data(ClosedLidHelper.script.utf8).base64EncodedString()))
        XCTAssertTrue(install.contains(Data(ClosedLidHelper.sudoers(user: "neel")!.utf8).base64EncodedString()))
        let visudo = try XCTUnwrap(install.range(of: "visudo -cqf"))
        let move = try XCTUnwrap(install.range(of: "'\(ClosedLidHelper.sudoersPath)'"))
        XCTAssertLessThan(visudo.lowerBound, move.lowerBound, "checked before it's moved in")
        XCTAssertFalse(install.contains("/tmp"), "nothing passes through a folder the user can write")
        for script in [install, ClosedLidHelper.uninstallScript] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("closed-lid-sh-\(UUID().uuidString)")
            try script.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(try run(["-n", file.path], shell: "/bin/sh"), 0)
        }
    }

    func testScriptParsesAndRejectsBadArguments() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("closed-lid-\(UUID().uuidString)")
        try ClosedLidHelper.script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(ClosedLidHelper.script.hasPrefix("#!/bin/bash\n"))
        XCTAssertEqual(try run(["-n", file.path]), 0)
        for bad in [[], ["enable"], ["enable-until"], ["enable-until", "abc"], ["enable-until", "0"],
                    ["enable-until", "12;id"], ["enable-until", "1", "2"], ["enable-until", "12345678901"],
                    ["status", "x"], ["disable", "x"], ["--help"]] {
            XCTAssertEqual(try run([file.path] + bad), 2, "\(bad)")
        }
    }

    private func run(_ arguments: [String], shell: String = "/bin/bash") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
