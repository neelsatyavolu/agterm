import XCTest
@testable import AgTermCore

final class SessionWireTests: XCTestCase {
    private let info = SessionInfo(id: "s1", pid: 4242, cwd: "/tmp", startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private var allMessages: [WireMessage] {
        [
            .hello(version: SessionWire.protocolVersion, build: "1.2.3"),
            .list,
            .sessions([info, SessionInfo(id: "s2", pid: 7, cwd: "/", startedAt: Date(timeIntervalSince1970: 1_700_000_100), attached: true)]),
            .spawn(SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"], env: ["A=1", "B=2"], cwd: "/tmp", cols: 80, rows: 24)),
            .attach(id: "s1"),
            .attached(info),
            .replay(Data([0x1b, 0x5b, 0x00, 0xff])),
            .output(Data("hello\r\n".utf8)),
            .exited(id: "s1", status: -1),
            .kill(id: "s1", signal: 15),
            .shutdownIfIdle,
            .error("boom"),
            .input(Data("ls\r".utf8)),
            .resize(WindowSize(cols: 120, rows: 40, width: 960, height: 640)),
            .auth(token: "t0k"),
            .inspect,
            .foreground(ForegroundInfo(pid: 9, isShell: false, name: "claude", argv: ["claude", "-c"], cwd: "/w",
                                       claudeSessionID: "abc", claudeBusy: true, codexSessionID: nil)),
            .exec(argv: ["/bin/sh", "-c", "rsync --server ."]),
            .stderr(Data("oops\n".utf8)),
            .signalForeground(15),
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
        XCTAssertThrowsError(try WireFrame.decode(&buffer)) {
            XCTAssertEqual($0 as? WireFrameError, .frameTooLarge(SessionWire.maxFrameLength + 1))
        }
    }

    /// A newer peer may send messages this version doesn't know; they are skipped, not fatal.
    func testUnknownTagIsSkipped() throws {
        var buffer = Data([0, 0, 0, 3, 0xEE, 0x01, 0x02])
        buffer.append(WireFrame.encode(.list))
        XCTAssertEqual(try WireFrame.decode(&buffer), .list)
        XCTAssertTrue(buffer.isEmpty)

        buffer = Data([0, 0, 0, 1, 0xEE])
        XCTAssertNil(try WireFrame.decode(&buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testIncompleteUnknownFrameIsKept() throws {
        var buffer = Data([0, 0, 0, 3, 0xEE, 0x01])
        XCTAssertNil(try WireFrame.decode(&buffer))
        XCTAssertEqual(buffer, Data([0, 0, 0, 3, 0xEE, 0x01]))
        buffer.append(0x02)
        buffer.append(WireFrame.encode(.shutdownIfIdle))
        XCTAssertEqual(try WireFrame.decode(&buffer), .shutdownIfIdle)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testBadJSONThrows() {
        var buffer = Data([0, 0, 0, 3, 0x05, 0x7b, 0x7b])
        XCTAssertThrowsError(try WireFrame.decode(&buffer)) {
            XCTAssertEqual($0 as? WireFrameError, .badPayload)
        }
    }

    // MARK: Compatibility contract

    func testGoldenBytes() {
        XCTAssertEqual(Array(WireFrame.encode(.list)), [0, 0, 0, 1, 2])
        XCTAssertEqual(Array(WireFrame.encode(.shutdownIfIdle)), [0, 0, 0, 1, 11])
        XCTAssertEqual(Array(WireFrame.encode(.output(Data("x".utf8)))), [0, 0, 0, 2, 8, 0x78])
        let json = #"{"build":"b","version":1}"#
        XCTAssertEqual(Array(WireFrame.encode(.hello(version: 1, build: "b"))),
                       [0, 0, 0, UInt8(1 + json.utf8.count), 1] + Array(json.utf8))
    }

    func testSessionInfoAttachedIsEncodedAndOptional() throws {
        let attached = SessionInfo(id: "s", pid: 1, cwd: "/", startedAt: Date(timeIntervalSince1970: 0), attached: true)
        let json = #"[{"attached":true,"cwd":"\/","id":"s","pid":1,"startedAt":"1970-01-01T00:00:00Z"}]"#
        XCTAssertEqual(Array(WireFrame.encode(.sessions([attached]))), [0, 0, 0, UInt8(1 + json.utf8.count), 3] + Array(json.utf8))
        // A helper from before the flag sends none: not attached.
        let old = #"[{"cwd":"/","id":"s","pid":1,"startedAt":"1970-01-01T00:00:00Z"}]"#
        var buffer = Data([0, 0, 0, UInt8(1 + old.utf8.count), 3] + Array(old.utf8))
        guard case .sessions(let infos)? = try WireFrame.decode(&buffer) else { return XCTFail("expected sessions") }
        XCTAssertEqual(infos.map(\.attached), [false])
    }

    func testEveryTagIsPinned() {
        let expected: [(WireMessage, UInt8)] = [
            (.hello(version: 1, build: "b"), 1), (.list, 2), (.sessions([]), 3),
            (.spawn(SpawnRequest(executable: "a", argv: [], env: [], cwd: "/", cols: 1, rows: 1)), 4),
            (.attach(id: "s"), 5), (.attached(info), 6), (.replay(Data()), 7), (.output(Data()), 8),
            (.exited(id: "s", status: 0), 9), (.kill(id: "s", signal: 9), 10), (.shutdownIfIdle, 11), (.error("e"), 12),
            (.input(Data()), 13), (.resize(WindowSize(cols: 1, rows: 1)), 14), (.auth(token: "t"), 15),
            (.inspect, 16), (.foreground(ForegroundInfo(pid: 1, isShell: true, name: "sh", argv: [], cwd: nil)), 17),
            (.exec(argv: []), 18), (.stderr(Data()), 19), (.signalForeground(2), 20),
        ]
        XCTAssertEqual(expected.count, allMessages.count)
        for (message, tag) in expected {
            XCTAssertEqual(WireFrame.encode(message)[4], tag, "\(message)")
        }
    }

    // MARK: Edge cases

    func testZeroLengthFrameThrows() {
        var buffer = Data([0, 0, 0, 0])
        XCTAssertThrowsError(try WireFrame.decode(&buffer)) {
            XCTAssertEqual($0 as? WireFrameError, .badPayload)
        }
    }

    func testMaxLengthHeaderWithoutBodyWaits() throws {
        let length = UInt32(SessionWire.maxFrameLength)
        var buffer = Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff), 0x08])
        let before = buffer
        XCTAssertNil(try WireFrame.decode(&buffer))
        XCTAssertEqual(buffer, before)
    }

    func testOneOverMaxLengthThrowsFrameTooLarge() {
        var buffer = Data([0x01, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try WireFrame.decode(&buffer)) {
            XCTAssertEqual($0 as? WireFrameError, .frameTooLarge(SessionWire.maxFrameLength + 1))
        }
    }

    func testEmptyRawPayloadsRoundTrip() throws {
        for message in [WireMessage.output(Data()), .replay(Data())] {
            var buffer = WireFrame.encode(message)
            XCTAssertEqual(try WireFrame.decode(&buffer), message)
            XCTAssertTrue(buffer.isEmpty)
        }
    }

    func testEmptyAndHeaderOnlyBuffersWait() throws {
        for start in [Data(), Data([0, 0, 0, 5])] {
            var buffer = start
            XCTAssertNil(try WireFrame.decode(&buffer))
            XCTAssertEqual(buffer, start)
        }
    }

    func testDecodesFromASliceWithNonZeroStartIndex() throws {
        var whole = Data([0xAA, 0xBB])
        whole.append(WireFrame.encode(.attach(id: "s1")))
        whole.append(WireFrame.encode(.list))
        var slice = whole.dropFirst(2)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(try WireFrame.decode(&slice), .attach(id: "s1"))
        XCTAssertEqual(try WireFrame.decode(&slice), .list)
        XCTAssertTrue(slice.isEmpty)
    }
}
