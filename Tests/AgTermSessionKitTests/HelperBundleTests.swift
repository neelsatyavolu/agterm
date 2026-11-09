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

    func testNilWhenTheExecutableIsntInTheApp() {
        XCTAssertNil(HelperBundle.executable(app: app, executable: URL(fileURLWithPath: "/bin/sh"), build: "1", folder: folder))
    }
}
#endif
