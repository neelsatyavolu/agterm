import AgTermCore
import Foundation
import XCTest

final class CloudSetupTests: XCTestCase {
    func testLockfilePicksThePackageManager() {
        XCTAssertEqual(CloudSetup.steps(files: ["package-lock.json", "yarn.lock"]).map(\.name), ["npm ci"])
        XCTAssertEqual(CloudSetup.steps(files: ["pnpm-lock.yaml"]).map(\.name), ["pnpm install"])
        XCTAssertEqual(CloudSetup.steps(files: ["yarn.lock", "requirements.txt"]).map(\.name), ["yarn install", "pip install"])
        XCTAssertEqual(CloudSetup.steps(files: ["bun.lockb"]).first?.inputs, ["bun.lockb"])
        XCTAssertEqual(CloudSetup.steps(files: ["README.md", "package.json"]), [])
    }

    func testCustomScriptReplacesTheKnownSteps() {
        let steps = CloudSetup.steps(files: ["package-lock.json", CloudSetup.customScript])
        XCTAssertEqual(steps.map(\.command), ["sh .agterm/cloud-setup.sh"])
        XCTAssertNil(steps.first?.output)
    }

    func testNothingToInstallGivesNoScript() {
        XCTAssertNil(CloudSetup.script(folder: "/w", steps: []))
    }

    func testQuotingSurvivesQuotes() {
        XCTAssertEqual(CloudSetup.quoted("it's"), "'it'\\''s'")
    }

    /// Runs the script for real: it installs once, skips while the lockfile is the same, and
    /// installs again when the lockfile or its output changes.
    func testScriptInstallsOnlyWhenNeeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("it's repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "v1".write(toFile: repo + "/lock", atomically: true, encoding: .utf8)
        let step = CloudSetup.Step(name: "fake", command: "mkdir -p out && echo x >> runs", inputs: ["lock"], output: "out")
        let script = try XCTUnwrap(CloudSetup.script(folder: repo, steps: [step]))
        let run = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        let runs = { (try? String(contentsOfFile: repo + "/runs", encoding: .utf8))?.split(separator: "\n").count ?? 0 }
        try run()
        try run()
        XCTAssertEqual(runs(), 1)
        try "v2".write(toFile: repo + "/lock", atomically: true, encoding: .utf8)
        try run()
        XCTAssertEqual(runs(), 2)
        try FileManager.default.removeItem(atPath: repo + "/out")
        try run()
        XCTAssertEqual(runs(), 3)
    }

    func testFailedStepRunsAgainNextTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let step = CloudSetup.Step(name: "fails", command: "echo x >> runs; false", inputs: [], output: nil)
        let script = try XCTUnwrap(CloudSetup.script(folder: root.path, steps: [step]))
        for _ in 0..<2 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8), "x\nx\n")
    }

    func testCopySizeWording() {
        XCTAssertEqual(CloudCopySize.minutes(1), 1)
        XCTAssertEqual(CloudCopySize.minutes(Int64(20 << 20) * 60 * 3), 3)
        XCTAssertTrue(CloudCopySize.askAbove > 500_000_000)
    }
}
