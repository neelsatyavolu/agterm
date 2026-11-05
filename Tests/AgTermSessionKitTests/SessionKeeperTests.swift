import AgTermCore
@testable import AgTermSessionKit
import Foundation
import XCTest

/// A cloud machine's sessions survive a stop: saved by the stopping server, started again with
/// the same ids, screens and agents by the next one.
final class SessionKeeperTests: XCTestCase {
    private var dir = ""
    private var savedHUP: sig_t?
    private var savedPIPE: sig_t?
    private var socket: String { dir + "/s.sock" }
    private var state: String { dir + "/kept.json" }

    override func setUpWithError() throws {
        savedHUP = signal(SIGHUP, SIG_IGN)
        savedPIPE = signal(SIGPIPE, SIG_IGN)
        var template = Array("/tmp/agkp.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        dir = String(cString: made)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        signal(SIGHUP, savedHUP)
        signal(SIGPIPE, savedPIPE)
    }

    func testResumeCommands() {
        let claude = ForegroundInfo(pid: 5, isShell: false, name: "claude", argv: ["claude", "--model", "opus"], cwd: "/w", claudeSessionID: "abc-123-def")
        XCTAssertTrue(SessionKeeper.resumeCommand(claude)?.contains("--resume abc-123-def") == true)
        let codex = ForegroundInfo(pid: 6, isShell: false, name: "node", argv: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex", "--yolo"], cwd: "/w",
                                   codexSessionID: "0199-abc")
        XCTAssertTrue(SessionKeeper.resumeCommand(codex)?.contains("resume 0199-abc") == true)
        XCTAssertNil(SessionKeeper.resumeCommand(ForegroundInfo(pid: 1, isShell: true, name: "bash", argv: ["-bash"], cwd: "/")))
        XCTAssertNil(SessionKeeper.resumeCommand(ForegroundInfo(pid: 7, isShell: false, name: "vim", argv: ["vim", "x"], cwd: "/")))
    }

    func testStoppedServerKeepsSessionsForTheNextOne() throws {
        let first = try server()
        let client = try connect()
        try client.send(.spawn(request(["sh"])))
        guard case .attached(let info) = try client.receive(timeout: 5) else { return XCTFail("expected attached") }
        let fd = try XCTUnwrap(client.takeFD())
        _ = "echo KEEP-$((1+1))\n".withCString { write(fd, $0, strlen($0)) }
        XCTAssertTrue(try collect(client, until: "KEEP-2").contains("KEEP-2"))
        close(fd)
        client.close()
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: state))

        let second = try server()
        defer { second.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state), "kept sessions are taken once")
        let again = try connect()
        defer { again.close() }
        try again.send(.list)
        guard case .sessions(let infos) = try again.receive(timeout: 5) else { return XCTFail("expected sessions") }
        XCTAssertEqual(infos.map(\.id), [info.id])
        try again.send(.attach(id: info.id))
        guard case .attached = try again.receive(timeout: 5) else { return XCTFail("expected attached") }
        if let fd = again.takeFD() { close(fd) }
        let screen = try collect(again, until: "restarted")
        XCTAssertTrue(screen.contains("KEEP-2") && screen.contains("restarted"), screen)
    }

    func testKeptAgentIsResumedAtTheFirstPrompt() throws {
        let kept = KeptSession(id: "kept-1", request: request(["sh"]), screen: Data("old screen\r\n".utf8), resume: "echo RESUMED-$((2+3))")
        SessionKeeper.save([kept], to: state)
        let server = try server()
        defer { server.stop() }
        let client = try connect()
        defer { client.close() }
        try client.send(.attach(id: "kept-1"))
        guard case .attached = try client.receive(timeout: 5) else { return XCTFail("expected attached") }
        if let fd = client.takeFD() { close(fd) }
        let text = try collect(client, until: "RESUMED-5")
        XCTAssertTrue(text.contains("old screen") && text.contains("RESUMED-5"), text)
    }

    // MARK: Helpers

    private func server() throws -> SessionServer {
        let server = SessionServer(socketPath: socket, build: "test")
        server.idleExitAfter = nil
        server.statePath = state
        try server.start()
        return server
    }

    private func request(_ argv: [String]) -> SpawnRequest {
        SpawnRequest(executable: "/bin/sh", argv: argv, env: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=$ "], cwd: "/tmp", cols: 80, rows: 24)
    }

    private func connect() throws -> WireConnection {
        let client = try WireConnection.connect(path: socket)
        _ = try client.handshake(build: "test")
        return client
    }

    private func collect(_ client: WireConnection, until needle: String) throws -> String {
        let deadline = Date().addingTimeInterval(5)
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
