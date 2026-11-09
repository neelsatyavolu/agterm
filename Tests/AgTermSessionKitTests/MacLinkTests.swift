#if canImport(Network)
import AgTermCore
@testable import AgTermSessionKit
import Foundation
import Network
import XCTest

/// A worker Mac in-process: `SessionServer`, a gateway with no TCP port of its own and a
/// `MacListener` on loopback. The client side is `MacLink.connect`, as `agterm-remote` uses it.
final class MacLinkTests: XCTestCase {
    private let secret = MacPairing.secret(from: (0..<32).map { UInt8($0) })
    private var dir = ""
    private var server: SessionServer!
    private var gateway: SessionGateway!
    private var listener: MacListener!
    private var savedPIPE: sig_t?

    override func setUpWithError() throws {
        savedPIPE = signal(SIGPIPE, SIG_IGN)
        var template = Array("/tmp/agml.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        dir = String(cString: made)
        server = SessionServer(socketPath: dir + "/s.sock", build: "test")
        server.idleExitAfter = nil
        try server.start()
        let account = RemoteSpawn.Account(user: "tester", home: dir, shell: "/bin/sh", path: "/usr/bin:/bin")
        gateway = SessionGateway(socketPath: dir + "/s.sock", host: "127.0.0.1", port: 0, token: MacLink.token(secret: secret), account: account)
        listener = try MacListener(port: 0, secret: secret, serviceName: nil) { [gateway] in gateway!.serve($0) }
        try listener.start()
    }

    override func tearDown() {
        listener.stop()
        gateway.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
        signal(SIGPIPE, savedPIPE)
    }

    func testTokenIsStableAndDependsOnTheSecret() {
        XCTAssertEqual(MacLink.token(secret: secret), MacLink.token(secret: secret))
        XCTAssertEqual(MacLink.token(secret: secret).count, 64)
        XCTAssertNotEqual(MacLink.token(secret: secret), MacLink.token(secret: MacPairing.secret(from: Array(repeating: 1, count: 32))))
    }

    func testExecRunsOverTheEncryptedLink() throws {
        let client = try connect(secret)
        defer { client.close() }
        try client.send(.auth(token: MacLink.token(secret: secret)))
        try client.send(.exec(argv: MacTask.execArgv(cwd: dir, command: "echo from-$((40+2)); exit 5")))
        try client.send(.input(Data()))
        var out = ""
        while true {
            switch try client.receive(timeout: 10) {
            case .output(let bytes): out += String(decoding: bytes, as: UTF8.self)
            case .exited(_, let status):
                XCTAssertEqual(out, "from-42\n")
                return XCTAssertEqual(status, 5)
            case .error(let text): return XCTFail(text)
            default: break
            }
        }
    }

    /// A Bonjour name that doesn't resolve (or any dead address) doesn't hold up the one that works.
    func testADeadEndpointDoesNotDelayALiveOne() throws {
        let dead = NWEndpoint.service(name: "agterm-test-\(UUID().uuidString)", type: MacLink.serviceType, domain: "local.", interface: nil)
        let live = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!)
        let started = Date()
        let fd = try MacLink.connect([dead, live], secret: secret, timeout: 5)
        close(fd)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testWrongSecretCannotConnect() {
        let other = MacPairing.secret(from: Array(repeating: 9, count: 32))
        XCTAssertThrowsError(try connect(other)) { error in
            XCTAssertTrue("\(error)".contains("pairing code"), "\(error)")
        }
    }

    func testRightLinkWrongTokenIsRefused() throws {
        let client = try connect(secret)
        defer { client.close() }
        try client.send(.auth(token: String(repeating: "0", count: 64)))
        XCTAssertEqual(try client.receive(timeout: 10), .error("unauthorized"))
    }

    /// Ctrl-C in `agterm-remote` drops the link: the command and what it started stop too.
    func testLeavingStopsTheCommandsChildren() throws {
        let client = try connect(secret)
        try client.send(.auth(token: MacLink.token(secret: secret)))
        try client.send(.exec(argv: ["/bin/sh", "-c", "sleep 30 & echo $!; wait"]))
        guard case .output(let bytes) = try client.receive(timeout: 10),
              let child = pid_t(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("expected the child's pid")
        }
        client.close()
        let deadline = Date().addingTimeInterval(8)
        while kill(child, 0) == 0, Date() < deadline { usleep(50_000) }
        XCTAssertNotEqual(kill(child, 0), 0, "the command's child \(child) kept running")
    }

    /// rsync pushes whole repos through it: nothing may be dropped or pile up either way.
    func testStreamsMegabytesBothWays() throws {
        let client = try connect(secret)
        defer { client.close() }
        let total = 8 * 1024 * 1024
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
        client.startReading(queue: DispatchQueue(label: "test.mac-link"))
        try client.send(.auth(token: MacLink.token(secret: secret)))
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

    private func connect(_ secret: String) throws -> WireConnection {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!)
        return WireConnection(fd: try MacLink.connect([endpoint], secret: secret, timeout: 5))
    }
}
#endif
