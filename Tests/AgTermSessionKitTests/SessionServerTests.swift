import AgTermCore
import AgTermSessionKit
import Foundation
import XCTest

/// Runs a `SessionServer` in-process on a socket in a fresh temp directory under /tmp.
final class SessionServerTests: XCTestCase {
    private var dir = ""
    private var server: SessionServer!
    private var pids: [pid_t] = []
    private var savedHUP: sig_t?
    private var savedPIPE: sig_t?
    private var socketPath: String { dir + "/s.sock" }

    override func setUpWithError() throws {
        // Like the real daemon: shells must not inherit these.
        savedHUP = signal(SIGHUP, SIG_IGN)
        savedPIPE = signal(SIGPIPE, SIG_IGN)
        var template = Array("/tmp/agst.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        dir = String(cString: made)
        server = SessionServer(socketPath: socketPath, build: "test")
        server.idleExitAfter = 60
        try server.start()
    }

    override func tearDown() {
        server.stop()
        for pid in pids { XCTAssertNotEqual(kill(pid, 0), 0, "child \(pid) outlived the server") }
        try? FileManager.default.removeItem(atPath: dir)
        signal(SIGHUP, savedHUP)
        signal(SIGPIPE, savedPIPE)
    }

    func testSpawnRunsCommandAndStreamsOutput() throws {
        let client = try connect()
        defer { client.close() }
        _ = try spawn(client, "echo HELLO; sleep 5")
        let fd = try XCTUnwrap(client.takeFD())
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        XCTAssertTrue(try collect(client, until: "HELLO", timeout: 2).contains("HELLO"))
    }

    func testReattachReplaysScreen() throws {
        let first = try connect()
        let info = try spawn(first, "printf 'MARK\\n'; sleep 5")
        _ = try collect(first, until: "MARK", timeout: 2)
        first.close()

        let second = try connect()
        defer { second.close() }
        try second.send(.attach(id: info.id))
        guard case .attached(let again) = try second.receive(timeout: 5) else { return XCTFail("expected attached") }
        XCTAssertEqual(again.pid, info.pid)
        if let fd = second.takeFD() { close(fd) } else { XCTFail("attach passed no fd") }
        guard case .replay(let screen) = try second.receive(timeout: 5) else { return XCTFail("expected replay") }
        XCTAssertTrue(String(decoding: screen, as: UTF8.self).contains("MARK"))
    }

    func testReadsWhileNoClientAttached() throws {
        let first = try connect()
        let info = try spawn(first, "yes | head -c 2000000; echo DONE; sleep 5")
        first.close()
        Thread.sleep(forTimeInterval: 2)

        let second = try connect()
        defer { second.close() }
        try second.send(.attach(id: info.id))
        guard case .attached = try second.receive(timeout: 5) else { return XCTFail("expected attached") }
        if let fd = second.takeFD() { close(fd) }
        guard case .replay(let screen) = try second.receive(timeout: 5) else { return XCTFail("expected replay") }
        XCTAssertTrue(String(decoding: screen, as: UTF8.self).contains("DONE"))
    }

    func testExitIsReportedAndSessionDropped() throws {
        let client = try connect()
        defer { client.close() }
        let info = try spawn(client, "exit 3")
        XCTAssertEqual(try waitForExit(client, id: info.id, timeout: 5), 3)
        try client.send(.list)
        guard case .sessions(let list) = try client.receive(timeout: 5) else { return XCTFail("expected sessions") }
        XCTAssertFalse(list.contains { $0.id == info.id })
    }

    func testKillEndsSession() throws {
        let client = try connect()
        defer { client.close() }
        let info = try spawn(client, executable: "/bin/sleep", argv: ["sleep", "30"])
        let sent = Date()
        try client.send(.kill(id: info.id, signal: SIGHUP))
        // Well inside the 2 s SIGKILL escalation, so SIGHUP itself ended it.
        XCTAssertEqual(try waitForExit(client, id: info.id, timeout: 1), 128 + SIGHUP)
        XCTAssertLessThan(Date().timeIntervalSince(sent), 1)
        XCTAssertNotEqual(kill(info.pid, 0), 0)
    }

    func testVersionMismatchIsRefused() throws {
        let client = try WireConnection.connect(path: socketPath)
        defer { client.close() }
        try client.send(.hello(version: SessionWire.protocolVersion + 1, build: "future"))
        XCTAssertEqual(try client.receive(timeout: 5), .hello(version: SessionWire.protocolVersion, build: "test"))
        XCTAssertEqual(try client.receive(timeout: 5), .error("protocol version mismatch"))
        XCTAssertThrowsError(try client.receive(timeout: 5))
    }

    // MARK: Helpers

    private func connect() throws -> WireConnection {
        let client = try WireConnection.connect(path: socketPath)
        let server = try client.handshake(build: "test")
        XCTAssertEqual(server.version, SessionWire.protocolVersion)
        return client
    }

    private func spawn(_ client: WireConnection, _ script: String) throws -> SessionInfo {
        try spawn(client, executable: "/bin/sh", argv: ["sh", "-c", script])
    }

    private func spawn(_ client: WireConnection, executable: String, argv: [String]) throws -> SessionInfo {
        let request = SpawnRequest(executable: executable, argv: argv, env: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                                   cwd: "/tmp", cols: 80, rows: 24)
        try client.send(.spawn(request))
        guard case .attached(let info) = try client.receive(timeout: 5) else {
            XCTFail("expected attached")
            throw POSIXError(.EPROTO)
        }
        pids.append(info.pid)
        return info
    }

    /// Accumulates replay and output text until it contains `needle` or the time is up.
    private func collect(_ client: WireConnection, until needle: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while !text.contains(needle) {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            switch try client.receive(timeout: left) {
            case .output(let bytes), .replay(let bytes): text += String(decoding: bytes, as: UTF8.self)
            default: break
            }
        }
        return text
    }

    private func waitForExit(_ client: WireConnection, id: String, timeout: TimeInterval) throws -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            if case .exited(let exitedID, let status) = try client.receive(timeout: deadline.timeIntervalSinceNow),
               exitedID == id { return status }
        }
        return nil
    }
}
