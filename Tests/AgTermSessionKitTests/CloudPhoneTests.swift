import AgTermCore
@testable import AgTermSessionKit
import Foundation
import XCTest

/// A `SessionServer` with a phone handoff, and a fake relay on loopback: once the Mac (the only
/// client) leaves, the server connects as the Mac's desktop and serves its sessions.
final class CloudPhoneTests: XCTestCase {
    private var dir = ""
    private var server: SessionServer!
    private var relay: FakeRelay!
    private var savedHUP: sig_t?
    private var savedPIPE: sig_t?

    override func setUpWithError() throws {
        savedHUP = signal(SIGHUP, SIG_IGN)
        savedPIPE = signal(SIGPIPE, SIG_IGN)
        var template = Array("/tmp/agph.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        dir = String(cString: made)
        relay = try FakeRelay()
        let handoff = CloudPhoneHandoff(desktopId: "desk-1", desktopSecret: String(repeating: "s", count: 40),
                                        relay: "ws://127.0.0.1:\(relay.port)/ws", deviceName: "agterm Cloud for Test",
                                        theme: "ink", home: dir, tabs: [.init(id: "tab-1", name: "api")])
        try JSONEncoder().encode(handoff).write(to: URL(fileURLWithPath: dir + "/phone.json"))
        server = SessionServer(socketPath: dir + "/s.sock", build: "test")
        server.idleExitAfter = nil
        server.phoneHandoffPath = dir + "/phone.json"
        server.phoneMacGoneAfter = 0
        try server.start()
    }

    override func tearDown() {
        server.stop()
        relay.stop()
        try? FileManager.default.removeItem(atPath: dir)
        signal(SIGHUP, savedHUP)
        signal(SIGPIPE, savedPIPE)
    }

    func testServesTabsTypingAndScreenOnceTheMacLeaves() throws {
        // The Mac opens a tab, then goes away.
        let mac = try WireConnection.connect(path: dir + "/s.sock")
        _ = try mac.handshake(build: "test")
        let request = SpawnRequest(executable: "/bin/sh", argv: ["sh"], env: ["AGTERM_TAB_ID=tab-1", "PS1=$ "], cwd: dir, cols: 80, rows: 24)
        try mac.send(.spawn(request))
        guard case .attached = try mac.receive(timeout: 5) else { return XCTFail("expected attached") }
        mac.close()

        let hello = try relay.next(timeout: 10) { $0["type"] as? String == "hello" }
        XCTAssertEqual(hello["role"] as? String, "desktop")
        XCTAssertEqual(hello["desktopId"] as? String, "desk-1")
        XCTAssertEqual(hello["deviceName"] as? String, "agterm Cloud for Test")
        XCTAssertTrue(relay.path.hasPrefix("/ws?desktopId=desk-1"))
        relay.send(["type": "hello.ok", "role": "desktop"])

        let snapshot = try relay.next(timeout: 10) { $0["type"] as? String == "threads.snapshot" }
        let threads = snapshot["threads"] as? [[String: Any]] ?? []
        XCTAssertEqual(threads.map { $0["id"] as? String }, ["tab-1"])
        XCTAssertEqual(threads.first?["title"] as? String, "api")
        XCTAssertEqual(threads.first?["provider"] as? String, "Terminal")

        relay.send(["type": "message.send", "threadId": "tab-1", "text": "echo phone-$((6*7))", "requestId": "r1"])
        let accepted = try relay.next(timeout: 5) { $0["type"] as? String == "message.accepted" }
        XCTAssertEqual(accepted["requestId"] as? String, "r1")

        relay.send(["type": "thread.subscribe", "threadId": "tab-1", "screen": true])
        let screen = try relay.next(timeout: 10) { message in
            guard message["threadId"] as? String == "screen:tab-1",
                  let lines = (message["screen"] as? [String: Any])?["lines"] as? [[[String: Any]]] else { return false }
            return lines.contains { $0.compactMap { $0["t"] as? String }.joined().contains("phone-42") }
        }
        XCTAssertEqual((screen["screen"] as? [String: Any])?["theme"] as? String, "ink")

        relay.send(["type": "thread.create", "provider": "claude", "projectId": dir, "requestId": "r2"])
        let refused = try relay.next(timeout: 5) { $0["type"] as? String == "error" }
        XCTAssertEqual(refused["requestId"] as? String, "r2")
    }

    /// The Mac took the relay back: the machine doesn't reconnect while the Mac stays.
    func testStaysOffOnceReplaced() throws {
        let mac = try WireConnection.connect(path: dir + "/s.sock")
        _ = try mac.handshake(build: "test")
        try mac.send(.spawn(SpawnRequest(executable: "/bin/sh", argv: ["sh"], env: ["AGTERM_TAB_ID=tab-1"], cwd: dir, cols: 80, rows: 24)))
        guard case .attached = try mac.receive(timeout: 5) else { return XCTFail("expected attached") }
        mac.close()
        _ = try relay.next(timeout: 10) { $0["type"] as? String == "hello" }
        relay.close(code: CloudPhoneRule.replacedCode)
        XCTAssertThrowsError(try relay.next(timeout: 6) { $0["type"] as? String == "hello" })
    }
}

/// The real relay over TLS, with `openssl s_client` (Linux cloud image): set
/// `AGTERM_RELAY_TLS_CHECK=1`. Sends only a ping before any hello, so no identity is made.
final class RelaySocketTLSTests: XCTestCase {
    func testTalksToTheRelayOverTLS() throws {
        guard ProcessInfo.processInfo.environment["AGTERM_RELAY_TLS_CHECK"] == "1" else { throw XCTSkip("set AGTERM_RELAY_TLS_CHECK=1") }
        let socket = try RelaySocket(url: URL(string: AgTermWire.defaultRelay + "?desktopId=" + UUID().uuidString.lowercased())!)
        let got = expectation(description: "a reply")
        socket.start(on: DispatchQueue(label: "tls-test")) { event in
            if case .text = event { got.fulfill() }
        }
        socket.send("{\"type\":\"ping\"}")
        wait(for: [got], timeout: 15)
        socket.close()
    }
}

/// A relay that takes one desktop connection at a time: JSON text messages both ways.
private final class FakeRelay: @unchecked Sendable {
    let port: UInt16
    private(set) var path = ""
    private let listenFd: Int32
    private let lock = NSCondition()
    private var messages: [[String: Any]] = []
    private var fd: Int32 = -1

    init() throws {
        (listenFd, port) = try TCPSocket.listen(host: "127.0.0.1", port: 0)
        _ = fcntl(listenFd, F_SETFL, fcntl(listenFd, F_GETFL) & ~O_NONBLOCK)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        shutdown(listenFd, Int32(SHUT_RDWR))
        Foundation.close(listenFd)
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    func send(_ message: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: message)
        WebSocketTransport.writeAll(fd, WebSocketTransport.frame(.text, Array(data)[...], masked: false))
    }

    func close(code: Int) {
        WebSocketTransport.writeAll(fd, WebSocketTransport.frame(.close, [UInt8(code >> 8), UInt8(code & 0xff)][...], masked: false))
        shutdown(fd, Int32(SHUT_RDWR))
    }

    /// The first message, received from now or earlier, that `matches`; throws on timeout.
    func next(timeout: TimeInterval, _ matches: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let index = messages.firstIndex(where: matches) {
                let found = messages[index]
                messages.removeSubrange(...index)
                return found
            }
            guard lock.wait(until: deadline) else { throw POSIXError(.ETIMEDOUT) }
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            guard let (header, rest) = WebSocketTransport.readHeader(client),
                  case .upgrade(let key) = WebSocketTransport.HandshakeRequest(header) else { Foundation.close(client); continue }
            path = String(header.split(separator: " ").dropFirst().first ?? "")
            WebSocketTransport.writeAll(client, Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(WebSocketTransport.accept(key))\r\n\r\n").utf8))
            fd = client
            Thread.detachNewThread { [self] in read(client, leftover: rest) }
        }
    }

    private func read(_ client: Int32, leftover: [UInt8]) {
        var reader = WebSocketTransport.FrameReader()
        reader.append(leftover[...])
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            while let (opcode, payload) = try? reader.next() {
                guard opcode == .text, let message = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { continue }
                lock.lock()
                messages.append(message)
                lock.broadcast()
                lock.unlock()
            }
            let count = Foundation.read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            reader.append(buffer[0..<count])
        }
    }
}
