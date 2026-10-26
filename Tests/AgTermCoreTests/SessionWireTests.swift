import XCTest
@testable import AgTermCore

final class SessionWireTests: XCTestCase {
    private let info = SessionInfo(id: "s1", pid: 4242, cwd: "/tmp", startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private var allMessages: [WireMessage] {
        [
            .hello(version: SessionWire.protocolVersion, build: "1.2.3"),
            .list,
            .sessions([info, SessionInfo(id: "s2", pid: 7, cwd: "/", startedAt: Date(timeIntervalSince1970: 1_700_000_100))]),
            .spawn(SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"], env: ["A=1", "B=2"], cwd: "/tmp", cols: 80, rows: 24)),
            .attach(id: "s1"),
            .attached(info),
            .replay(Data([0x1b, 0x5b, 0x00, 0xff])),
            .output(Data("hello\r\n".utf8)),
            .exited(id: "s1", status: -1),
            .kill(id: "s1", signal: 15),
            .shutdownIfIdle,
            .error("boom"),
        ]
    }

    func testEveryMessageRoundTrips() throws {
        for message in allMessages {
            var buffer = WireFrame.encode(message)
            XCTAssertEqual(try WireFrame.decode(&buffer), message)
            XCTAssertTrue(buffer.isEmpty)
        }
    }

    func testPartialFrameReturnsNilAndKeepsBytes() throws {
        let frame = WireFrame.encode(.attach(id: "s1"))
        var buffer = frame.prefix(3)
        XCTAssertNil(try WireFrame.decode(&buffer))
        XCTAssertEqual(buffer, frame.prefix(3))
        buffer = frame.dropLast()
        XCTAssertNil(try WireFrame.decode(&buffer))
        XCTAssertEqual(buffer, frame.dropLast())
        buffer.append(frame.last!)
        XCTAssertEqual(try WireFrame.decode(&buffer), .attach(id: "s1"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTwoFramesInOneBuffer() throws {
        var buffer = WireFrame.encode(.list)
        buffer.append(WireFrame.encode(.output(Data("x".utf8))))
        XCTAssertEqual(try WireFrame.decode(&buffer), .list)
        XCTAssertEqual(try WireFrame.decode(&buffer), .output(Data("x".utf8)))
        XCTAssertNil(try WireFrame.decode(&buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOversizedLengthThrows() {
        let length = UInt32(16 * 1024 * 1024 + 1)
        var buffer = Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff), 0x01])
        XCTAssertThrowsError(try WireFrame.decode(&buffer))
    }

    func testUnknownTagThrows() {
        var buffer = Data([0, 0, 0, 1, 0xEE])
        XCTAssertThrowsError(try WireFrame.decode(&buffer))
    }

    func testBadJSONThrows() {
        var buffer = Data([0, 0, 0, 3, 0x05, 0x7b, 0x7b])
        XCTAssertThrowsError(try WireFrame.decode(&buffer))
    }
}
