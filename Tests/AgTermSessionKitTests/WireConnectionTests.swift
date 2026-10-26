import AgTermCore
@testable import AgTermSessionKit
import Foundation
import XCTest

final class WireConnectionTests: XCTestCase {
    private var dirs: [String] = []

    override func tearDown() {
        for dir in dirs {
            chmod(dir, 0o700)
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// An attacker could pre-create the socket directory and listen in it; the client must refuse.
    func testConnectRefusesDirectoryOthersCanWrite() throws {
        let dir = try makeDir()
        let listener = try UnixSocket.listen(path: dir + "/s.sock")
        defer { close(listener) }
        XCTAssertEqual(chmod(dir, 0o777), 0)
        XCTAssertThrowsError(try WireConnection.connect(path: dir + "/s.sock")) {
            XCTAssertEqual($0 as? SessionPathError, .untrustedDirectory(dir))
        }
        XCTAssertEqual(chmod(dir, 0o700), 0)
        XCTAssertNoThrow(try WireConnection.connect(path: dir + "/s.sock").close())
    }

    func testConnectRefusesSymlinkedDirectory() throws {
        let dir = try makeDir()
        let listener = try UnixSocket.listen(path: dir + "/s.sock")
        defer { close(listener) }
        let link = dir + ".link"
        XCTAssertEqual(symlink(dir, link), 0)
        defer { unlink(link) }
        XCTAssertThrowsError(try WireConnection.connect(path: link + "/s.sock")) {
            XCTAssertEqual($0 as? SessionPathError, .untrustedDirectory(link))
        }
    }

    func testPeerOfAnotherUserIsRefused() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { close($0) } }
        XCTAssertNoThrow(try UnixSocket.requirePeer(fds[0], uid: getuid()))
        XCTAssertThrowsError(try UnixSocket.requirePeer(fds[0], uid: getuid() &+ 1)) {
            XCTAssertEqual($0 as? WireError, .untrustedPeer)
        }
    }

    /// One message bigger than the backlog cap (a large replay) must reach an idle client
    /// whole, along with the output that follows it, without the server dropping it.
    func testMessageLargerThanBacklogCapIsDelivered() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let queue = DispatchQueue(label: "test.server")
        let server = WireConnection(fd: fds[0])
        let client = WireConnection(fd: fds[1])
        defer { server.close(); client.close() }
        server.startReading(queue: queue)

        let big = Data(repeating: 0x61, count: 9 * 1024 * 1024)
        try queue.sync {
            try server.send(.replay(big))
            try server.send(.output(Data("after".utf8)))
        }
        var received = 0
        while received < big.count {
            guard case .replay(let part) = try client.receive(timeout: 5) else { return XCTFail("expected replay") }
            received += part.count
        }
        XCTAssertEqual(received, big.count)
        XCTAssertEqual(try client.receive(timeout: 5), .output(Data("after".utf8)))
        try queue.sync { try server.send(.list) }
        XCTAssertEqual(try client.receive(timeout: 5), .list)
    }

    /// A client reads `attached` blocking, then switches to events: whatever arrived with it
    /// (the replay) must still be delivered, without waiting for more bytes.
    func testStartReadingDeliversMessagesAlreadyBuffered() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let server = WireConnection(fd: fds[0])
        let client = WireConnection(fd: fds[1])
        defer { server.close(); client.close() }
        try server.send(.list)
        try server.send(.output(Data("buffered".utf8)))
        XCTAssertEqual(try client.receive(timeout: 2), .list)
        let got = expectation(description: "buffered output")
        client.onMessage = { if $0 == .output(Data("buffered".utf8)) { got.fulfill() } }
        client.startReading(queue: DispatchQueue(label: "test.client"))
        wait(for: [got], timeout: 2)
    }

    func testPausedReadingDeliversNothingUntilResumed() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let server = WireConnection(fd: fds[0])
        let client = WireConnection(fd: fds[1])
        defer { server.close(); client.close() }
        let queue = DispatchQueue(label: "test.client")
        var received: [WireMessage] = []
        client.onMessage = { received.append($0) }
        client.startReading(queue: queue)
        client.pauseReading()
        try server.send(.output(Data("later".utf8)))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(queue.sync { received }, [])
        client.resumeReading()
        let deadline = Date().addingTimeInterval(2)
        while queue.sync(execute: { received.isEmpty }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(queue.sync { received }, [.output(Data("later".utf8))])
        // Closing while paused must not crash (a suspended source can't be released).
        client.pauseReading()
    }

    private func makeDir() throws -> String {
        var template = Array("/tmp/agwc.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        let dir = String(cString: made)
        dirs.append(dir)
        return dir
    }
}
