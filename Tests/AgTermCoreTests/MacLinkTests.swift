@testable import AgTermCore
import XCTest

final class MacPairingTests: XCTestCase {
    private let secret = MacPairing.secret(from: Array(repeating: 7, count: 32))

    func testCodeRoundTrips() throws {
        let pairing = MacPairing(name: "Studio", host: "studio.local", port: 47821, secret: secret)
        XCTAssertTrue(pairing.code.hasPrefix("agterm-mac:"))
        XCTAssertEqual(MacPairing(code: "  " + pairing.code + "\n"), pairing)
    }

    func testSecretIsBase64urlOf32Bytes() {
        XCTAssertEqual(secret.count, MacPairing.secretLength)
        XCTAssertFalse(secret.contains("="))
        XCTAssertEqual(MacPairing.data(base64url: secret)?.count, 32)
    }

    func testRejectsOtherTextAndBadFields() {
        XCTAssertNil(MacPairing(code: "hello"))
        XCTAssertNil(MacPairing(code: "agterm-mac:not-json"))
        for bad in [MacPairing(name: "", host: "h", port: 1, secret: secret),
                    MacPairing(name: "n", host: "", port: 1, secret: secret),
                    MacPairing(name: "n", host: "h", port: 0, secret: secret),
                    MacPairing(name: "n", host: "h", port: 1, secret: "short")] {
            XCTAssertNil(MacPairing(code: bad.code), "\(bad)")
        }
    }
}

final class MacTaskTests: XCTestCase {
    func testParsesRunWithOptions() throws {
        XCTAssertEqual(try MacTask.parse(["run", "--mac", "Studio", "--no-sync", "--back", "--", "make -j8 && ./test"]),
                       .run(.init(mac: "Studio", sync: false, back: true, command: "make -j8 && ./test")))
    }

    func testSeveralWordsAreQuoted() throws {
        XCTAssertEqual(try MacTask.parse(["run", "--", "echo", "it's", "a b"]),
                       .run(.init(command: #"echo 'it'\''s' 'a b'"#)))
        XCTAssertEqual(try MacTask.parse(["run", "npm", "test"]), .run(.init(command: "npm test")))
    }

    func testOptionsAfterDashDashBelongToTheCommand() throws {
        XCTAssertEqual(try MacTask.parse(["run", "--", "ls", "--back"]), .run(.init(command: "ls --back")))
    }

    func testUsageErrors() {
        XCTAssertEqual(try MacTask.parse([]), .help)
        XCTAssertEqual(try MacTask.parse(["list"]), .list)
        XCTAssertThrowsError(try MacTask.parse(["run"]))
        XCTAssertThrowsError(try MacTask.parse(["run", "--"]))
        XCTAssertThrowsError(try MacTask.parse(["run", "--mac"]))
        XCTAssertThrowsError(try MacTask.parse(["run", "--fast", "--", "x"]))
        XCTAssertThrowsError(try MacTask.parse(["go"]))
    }

    func testRemoteFolderKeepsItsPlaceUnderTheTasksFolder() {
        XCTAssertEqual(MacTask.remoteFolder("/Users/neel/code/app", localHome: "/Users/neel", remoteHome: "/Users/sam", client: "Neel's MacBook"),
                       "/Users/sam/agterm-tasks/Neel-s-MacBook/code/app")
        XCTAssertEqual(MacTask.remoteFolder("/opt/src/app", localHome: "/Users/neel/", remoteHome: "/Users/sam", client: "mb"),
                       "/Users/sam/agterm-tasks/mb/root/opt/src/app")
        // A sibling whose name starts like the home isn't inside it.
        XCTAssertEqual(MacTask.remoteFolder("/Users/neelx/app", localHome: "/Users/neel", remoteHome: "/r", client: "mb"),
                       "/r/agterm-tasks/mb/root/Users/neelx/app")
    }

    func testRemoteCwd() {
        XCTAssertEqual(MacTask.remoteCwd("/a/repo/sub/dir", folder: "/a/repo", remote: "/r/x"), "/r/x/sub/dir")
        XCTAssertEqual(MacTask.remoteCwd("/a/repo", folder: "/a/repo", remote: "/r/x"), "/r/x")
        XCTAssertEqual(MacTask.remoteCwd("/a/repository", folder: "/a/repo", remote: "/r/x"), "/r/x")
    }

    func testExecArgvRunsTheCommandInTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactask-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let argv = MacTask.execArgv(cwd: dir, command: "pwd -P; echo \"$0\" >/dev/null; exit 4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": dir]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(printed.trimmingCharacters(in: .whitespacesAndNewlines), realpath(dir, nil).map { String(cString: $0) })
        XCTAssertEqual(process.terminationStatus, 4)
    }
}
