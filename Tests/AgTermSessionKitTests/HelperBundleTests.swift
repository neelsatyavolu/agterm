#if os(macOS)
import AgTermSessionKit
import XCTest

final class HelperBundleTests: XCTestCase {
    private var root: URL!
    private var app: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HelperBundleTests-\(UUID().uuidString)")
        app = root.appendingPathComponent("Applications/agterm.app")
        folder = root.appendingPathComponent("state/helpers")
        try writeExecutable("first")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var executable: URL { app.appendingPathComponent("Contents/MacOS/agterm") }

    private func writeExecutable(_ text: String) throws {
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: executable)
        try Data(text.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func copy(build: String = "1.2.0") -> URL? {
        HelperBundle.executable(app: app, executable: executable, build: build, folder: folder)
    }

    func testRunsFromACopyOutsideTheApp() throws {
        let path = try XCTUnwrap(copy())
        XCTAssertTrue(path.path.hasPrefix(folder.path + "/"))
        XCTAssertTrue(path.path.hasSuffix("/agterm.app/Contents/MacOS/agterm"))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "first")
    }

    func testReusesTheCopyForTheSameBinary() throws {
        let first = try XCTUnwrap(copy())
        XCTAssertEqual(try XCTUnwrap(copy()), first)
    }

    /// An update or reinstall replaces the app: the next helper gets a new copy, and the copy
    /// no running process uses is removed.
    func testAnotherBinaryGetsAnotherCopyAndTheUnusedOneGoes() throws {
        let first = try XCTUnwrap(copy())
        try writeExecutable("second, a longer binary")
        let second = try XCTUnwrap(copy())
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second, a longer binary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    /// The copy a helper still runs from is never removed: deleting it would cost that helper
    /// its permissions just like replacing the app did.
    func testKeepsACopyARunningProcessUses() throws {
        let first = try XCTUnwrap(copy(build: "1.1.0"))
        // A system binary copied elsewhere is killed at launch, so build a sleeper of our own.
        let source = root.appendingPathComponent("sleeper.c")
        try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = ["clang", "-o", first.path, source.path]
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0)
        let sleeper = Process()
        sleeper.executableURL = first
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        _ = try XCTUnwrap(copy(build: "1.2.0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    /// Helpers from before 1.2.1 ran from the app itself: an update replaced the file under them.
    func testTellsWhenAProcesssFileWasReplacedAfterItStarted() throws {
        let binary = root.appendingPathComponent("sleeper")
        try buildSleeper(at: binary)
        let sleeper = Process()
        sleeper.executableURL = binary
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        XCTAssertFalse(HelperBundle.runsReplacedFile(pid: sleeper.processIdentifier, executable: binary))
        XCTAssertFalse(HelperBundle.runsReplacedFile(pid: sleeper.processIdentifier, executable: executable))
        Thread.sleep(forTimeInterval: 0.05)
        let update = root.appendingPathComponent("sleeper-new")
        try buildSleeper(at: update)
        XCTAssertEqual(rename(update.path, binary.path), 0)
        XCTAssertTrue(HelperBundle.runsReplacedFile(pid: sleeper.processIdentifier, executable: binary))
    }

    /// An update moves the old app away and deletes it; the kernel then has no path for the process.
    func testTellsWhenAProcesssFileWasDeleted() throws {
        let folder = root.appendingPathComponent("old.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("sleeper")
        try buildSleeper(at: binary)
        let sleeper = Process()
        sleeper.executableURL = binary
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        // Let it finish loading before its file goes.
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try buildSleeper(at: binary)
        XCTAssertTrue(sleeper.isRunning)
        XCTAssertTrue(HelperBundle.runsReplacedFile(pid: sleeper.processIdentifier, executable: binary))
    }

    private func buildSleeper(at binary: URL) throws {
        let source = root.appendingPathComponent("sleeper.c")
        try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = ["clang", "-o", binary.path, source.path]
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0)
    }

    func testNilWhenTheExecutableIsntInTheApp() {
        XCTAssertNil(HelperBundle.executable(app: app, executable: URL(fileURLWithPath: "/bin/sh"), build: "1", folder: folder))
    }
}
#endif
