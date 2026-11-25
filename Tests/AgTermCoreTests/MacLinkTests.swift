@testable import AgTermCore
import XCTest

final class MacPairingTests: XCTestCase {
    private let secret = MacPairing.secret(from: Array(repeating: 7, count: 32))

    func testCodeRoundTrips() throws {
        let pairing = MacPairing(name: "Studio", host: "studio.local", port: 47821, secret: secret)
        XCTAssertTrue(pairing.code.hasPrefix("agterm-mac:"))
        XCTAssertEqual(MacPairing(code: "  " + pairing.code + "\n"), pairing)
    }

    func testWindowsCodeKeepsSystemAndAddresses() throws {
        let pc = MacPairing(name: "DESKTOP-1", host: "desktop-1.local", port: 47821, secret: secret,
                            system: "windows", addresses: ["192.168.1.20"])
        let decoded = try XCTUnwrap(MacPairing(code: pc.code))
        XCTAssertTrue(decoded.isWindows)
        XCTAssertEqual(decoded.addresses, ["192.168.1.20"])
        // A Mac's code has neither field, as older builds wrote it.
        let mac = MacPairing(name: "Studio", host: "studio.local", port: 47821, secret: secret)
        XCTAssertFalse(mac.code.contains("system"))
        XCTAssertFalse(try XCTUnwrap(MacPairing(code: mac.code)).isWindows)
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
                       .run(.init(command: #"echo 'it'\''s' 'a b'"#, windowsCommand: "echo 'it''s' 'a b'")))
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

final class WindowsSyncTests: XCTestCase {
    func testParsesManifestRecords() {
        let data = Data("a.txt\t3\t100\0dir/b c\t10\t200\0tab\tname\t1\t2\0bad\0\0".utf8)
        XCTAssertEqual(WindowsSync.parseManifest(data), [
            "a.txt": .init(size: 3, mtime: 100),
            "dir/b c": .init(size: 10, mtime: 200),
            "tab\tname": .init(size: 1, mtime: 2),
        ])
    }

    func testPlanSendsChangedAndRemovesGoneButKeepsIgnored() {
        let local: [String: WindowsSync.Entry] = ["same": .init(size: 1, mtime: 1), "newer": .init(size: 1, mtime: 2), "new": .init(size: 5, mtime: 5)]
        let remote: [String: WindowsSync.Entry] = ["same": .init(size: 1, mtime: 1), "newer": .init(size: 1, mtime: 1),
                                                   "gone": .init(size: 1, mtime: 1), "bin/out.exe": .init(size: 9, mtime: 9)]
        let plan = WindowsSync.plan(local: local, remote: remote) { $0.hasPrefix("bin/") }
        XCTAssertEqual(plan, .init(send: ["new", "newer"], delete: ["gone"]))
    }

    func testExcludedFoldersAndArguments() {
        XCTAssertTrue(WindowsSync.isExcluded("web/node_modules/x/index.js", excluded: ["node_modules"]))
        XCTAssertFalse(WindowsSync.isExcluded("src/node_modules.md", excluded: ["node_modules"]))
        XCTAssertFalse(WindowsSync.isExcluded("target", excluded: ["target"]))
        XCTAssertEqual(WindowsSync.skipArguments(["a", "b"]), ["--skip", "a", "--skip", "b"])
        XCTAssertEqual(WindowsSync.pathList(["a", "b/c"]), Data("a\0b/c\0".utf8))
    }

    func testParsesInfo() {
        XCTAssertEqual(WindowsSync.parseInfo(#"{"version":"1.0.0","system":"windows","home":"C:/Users/neel","shell":"pwsh"}"# + "\n"),
                       .init(version: "1.0.0", system: "windows", home: "C:/Users/neel", shell: "pwsh"))
        XCTAssertNil(WindowsSync.parseInfo("nope"))
    }

    func testRemoteFolderUnderAWindowsHome() {
        XCTAssertEqual(MacTask.remoteFolder("/Users/neel/code/app", localHome: "/Users/neel", remoteHome: "C:/Users/neel", client: "Neel's Mac"),
                       "C:/Users/neel/agterm-tasks/Neel-s-Mac/code/app")
    }
}

final class RemoteInstructionsTests: XCTestCase {
    func testNothingPairedSaysNothing() {
        XCTAssertNil(RemoteInstructions.text([]))
    }

    func testMacsOnlyDoesNotMentionPowerShell() throws {
        let text = try XCTUnwrap(RemoteInstructions.text([.init(name: "Studio", isWindows: false)]))
        XCTAssertTrue(text.contains(#"Macs "Studio""#))
        XCTAssertTrue(text.contains(#"default "Studio""#))
        XCTAssertFalse(text.contains("PowerShell"))
    }

    func testWindowsPCGetsPowerShellGuidance() throws {
        let text = try XCTUnwrap(RemoteInstructions.text([.init(name: "Studio", isWindows: false), .init(name: "DESKTOP-1", isWindows: true)]))
        XCTAssertTrue(text.contains(#"Macs "Studio" and Windows PCs "DESKTOP-1""#))
        XCTAssertTrue(text.contains("PowerShell"))
        XCTAssertTrue(text.contains(#"--mac "DESKTOP-1""#))
    }

    func testPairedNoteIsOneMarkedLineWithoutControls() {
        let note = RemoteInstructions.pairedNote(.init(name: "PC\u{1b}[2J\u{15}\r", isWindows: true))
        XCTAssertTrue(note.hasPrefix("[Note from agterm, not from your user"))
        XCTAssertFalse(note.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertTrue(note.contains("PowerShell"))
    }
}
