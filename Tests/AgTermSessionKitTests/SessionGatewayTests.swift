import AgTermCore
@testable import AgTermSessionKit
import Foundation
import XCTest

/// A `SessionServer` and a `SessionGateway` in-process; clients connect over loopback TCP, as
/// the Mac app does to a cloud machine.
final class SessionGatewayTests: XCTestCase {
    private let token = String(repeating: "k", count: 32)
    private var dir = ""
    private var server: SessionServer!
    private var gateway: SessionGateway!
    private var savedHUP: sig_t?
    private var savedPIPE: sig_t?

    override func setUpWithError() throws {
        savedHUP = signal(SIGHUP, SIG_IGN)
        savedPIPE = signal(SIGPIPE, SIG_IGN)
        var template = Array("/tmp/aggw.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        dir = String(cString: made)
        server = SessionServer(socketPath: dir + "/s.sock", build: "test")
        server.idleExitAfter = nil
        try server.start()
        let account = RemoteSpawn.Account(user: "tester", home: dir, shell: "/bin/sh", path: "/usr/bin:/bin")
        gateway = SessionGateway(socketPath: dir + "/s.sock", host: "127.0.0.1", port: 0, token: token, account: account)
        gateway.authTimeout = 0.5
        try gateway.start()
    }

    override func tearDown() {
        gateway.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
        signal(SIGHUP, savedHUP)
        signal(SIGPIPE, savedPIPE)
    }

    func testWrongTokenIsRefused() throws {
        let client = try open()
        defer { client.close() }
        try client.send(.auth(token: String(repeating: "x", count: 32)))
        XCTAssertEqual(try client.receive(timeout: 5), .error("unauthorized"))
        XCTAssertThrowsError(try client.receive(timeout: 5))
    }

    func testClientThatNeverAuthenticatesIsDropped() throws {
        let client = try open()
        defer { client.close() }
        XCTAssertThrowsError(try client.receive(timeout: 5)) { XCTAssertEqual($0 as? WireError, .closed) }
    }

    func testTypesIntoShellAndReplaysOnReattach() throws {
        let first = try connect()
        let info = try spawn(first)
        XCTAssertNil(first.takeFD(), "a pty descriptor crossed the gateway")
        try first.send(.input(Data("echo cloud-$((40+2))\r".utf8)))
        XCTAssertTrue(try collect(first, until: "cloud-42").contains("cloud-42"))
        first.close()

        let second = try connect()
        defer { second.close() }
        try second.send(.attach(id: info.id))
        guard case .attached = try second.receive(timeout: 5) else { return XCTFail("expected attached") }
        XCTAssertNil(second.takeFD())
        XCTAssertTrue(try collect(second, until: "cloud-42").contains("cloud-42"))
    }

    /// The machine's own shell, home and PATH; the Mac's other variables never arrive.
    func testSpawnUsesThisMachinesShellAndDropsClientSecrets() throws {
        let client = try connect()
        defer { client.close() }
        _ = try spawn(client, env: ["TERM=xterm-256color", "SECRET_KEY=hunter2", "PATH=/mac/bin"])
        try client.send(.input(Data("echo \"[$0|$HOME|$PATH|${SECRET_KEY:-none}]\"\r".utf8)))
        let text = try collect(client, until: "none]")
        // A login shell may extend PATH (macOS's /etc/profile does), but never with the Mac's.
        XCTAssertTrue(text.contains("[-sh|\(dir)|"), text.debugDescription)
        XCTAssertTrue(text.contains("|none]"), text.debugDescription)
        XCTAssertFalse(text.contains("/mac/bin"), text.debugDescription)
    }

    func testResizeReachesTheShell() throws {
        let client = try connect()
        defer { client.close() }
        _ = try spawn(client)
        try client.send(.resize(WindowSize(cols: 101, rows: 33)))
        try client.send(.input(Data("stty size\r".utf8)))
        XCTAssertTrue(try collect(client, until: "33 101").contains("33 101"))
    }

    /// The app can't look at the cloud machine's processes, so the helper reports the foreground.
    func testInspectReportsTheForegroundProgram() throws {
        let client = try connect()
        defer { client.close() }
        _ = try spawn(client)
        try client.send(.inspect)
        let atPrompt = try foreground(client)
        XCTAssertTrue(atPrompt.isShell)
        XCTAssertNotNil(atPrompt.cwd)
        try client.send(.input(Data("sleep 30\r".utf8)))
        let deadline = Date().addingTimeInterval(5)
        var running = atPrompt
        while running.isShell, Date() < deadline {
            usleep(100_000)
            try client.send(.inspect)
            running = try foreground(client)
        }
        XCTAssertFalse(running.isShell)
        XCTAssertEqual(running.argv, ["sleep", "30"])
        XCTAssertEqual(running.name, "sleep")
    }

    func testExecPipesInputOutputAndStatus() throws {
        let client = try authenticated()
        defer { client.close() }
        try client.send(.exec(argv: ["/bin/sh", "-c", "cat; echo err >&2; exit 3"]))
        try client.send(.input(Data("hello".utf8)))
        try client.send(.input(Data()))
        var out = "", err = ""
        while true {
            switch try client.receive(timeout: 5) {
            case .output(let bytes): out += String(decoding: bytes, as: UTF8.self)
            case .stderr(let bytes): err += String(decoding: bytes, as: UTF8.self)
            case .exited(_, let status):
                XCTAssertEqual([out, err], ["hello", "err\n"])
                XCTAssertEqual(status, 3)
                return XCTAssertThrowsError(try client.receive(timeout: 5))
            default: break
            }
        }
    }

    /// rsync moves whole folders: input and output both outrun the other end, and neither the
    /// gateway nor the connection may drop or pile up bytes.
    func testExecStreamsMegabytesBothWays() throws {
        let client = try authenticated()
        defer { client.close() }
        let total = 6 * 1024 * 1024
        let lock = NSLock()
        var received = 0
        let done = expectation(description: "exited")
        client.onMessage = { message in
            switch message {
            case .output(let bytes): lock.lock(); received += bytes.count; lock.unlock()
            case .exited(_, let status): XCTAssertEqual(status, 0); done.fulfill()
            default: break
            }
        }
        client.startReading(queue: DispatchQueue(label: "test.exec"))
        try client.send(.exec(argv: ["/bin/cat"]))
        let chunk = Data(repeating: 0x2a, count: 64 * 1024)
        for _ in 0..<(total / chunk.count) {
            while client.backlogBytes > 1024 * 1024 { usleep(1000) }
            try client.send(.input(chunk))
        }
        try client.send(.input(Data()))
        wait(for: [done], timeout: 30)
        lock.lock()
        XCTAssertEqual(received, total)
        lock.unlock()
    }

    /// The client hanging up mid-command kills it, and the gateway still reaps it (no zombie).
    func testExecIsKilledAndReapedWhenTheClientLeaves() throws {
        let client = try authenticated()
        try client.send(.exec(argv: ["/bin/sh", "-c", "echo $$; exec sleep 30"]))
        guard case .output(let bytes) = try client.receive(timeout: 5),
              let pid = pid_t(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("expected the pid")
        }
        client.close()
        let deadline = Date().addingTimeInterval(5)
        // kill(pid, 0) still succeeds on a zombie; it fails once the process is reaped.
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "exec'd command \(pid) wasn't killed and reaped")
    }

    func testExecOfAMissingCommandIsRefused() throws {
        let client = try authenticated()
        defer { client.close() }
        try client.send(.exec(argv: ["/no/such/command"]))
        guard case .error(let text) = try client.receive(timeout: 5) else { return XCTFail("expected error") }
        XCTAssertTrue(text.hasPrefix("exec failed"), text)
    }

    func testRemoteClientCannotShutDownTheHelper() throws {
        let client = try connect()
        defer { client.close() }
        try client.send(.shutdownIfIdle)
        try client.send(.list)
        XCTAssertEqual(try client.receive(timeout: 5), .sessions([]))
    }

    // MARK: Helpers

    private func open() throws -> WireConnection {
        WireConnection(fd: try TCPSocket.connect(host: "127.0.0.1", port: gateway.port, timeout: 5))
    }

    private func authenticated() throws -> WireConnection {
        let client = try open()
        try client.send(.auth(token: token))
        return client
    }

    private func connect() throws -> WireConnection {
        let client = try authenticated()
        XCTAssertEqual(try client.handshake(build: "test").version, SessionWire.protocolVersion)
        return client
    }

    /// The Mac's shell and folder, which the gateway replaces.
    private func spawn(_ client: WireConnection, env: [String] = ["TERM=xterm-256color"]) throws -> SessionInfo {
        let request = SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"], env: env, cwd: "/Users/nobody/project", cols: 80, rows: 24)
        try client.send(.spawn(request))
        guard case .attached(let info) = try client.receive(timeout: 5) else {
            XCTFail("expected attached")
            throw POSIXError(.EPROTO)
        }
        return info
    }

    /// The next `foreground` reply, skipping output.
    private func foreground(_ client: WireConnection) throws -> ForegroundInfo {
        while true {
            if case .foreground(let info) = try client.receive(timeout: 5) { return info }
        }
    }

    private func collect(_ client: WireConnection, until needle: String, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while !text.contains(needle), deadline.timeIntervalSinceNow > 0 {
            switch try client.receive(timeout: deadline.timeIntervalSinceNow) {
            case .output(let bytes), .replay(let bytes): text += String(decoding: bytes, as: UTF8.self)
            default: break
            }
        }
        return text
    }
}
