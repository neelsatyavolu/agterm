@testable import AgTermSessionKit
import Foundation
import XCTest

final class WebSocketTransportTests: XCTestCase {
    func testSHA1KnownAnswers() {
        let hex = { (bytes: [UInt8]) in bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(SHA1.hash([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(SHA1.hash(Array(String(repeating: "a", count: 1000).utf8))), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    /// RFC 6455 §1.3's example.
    func testAcceptKey() {
        XCTAssertEqual(WebSocketTransport.accept("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testHandshakeRequests() {
        let upgrade = "GET / HTTP/1.1\r\nHost: x\r\nUPGRADE: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: abc==\r\nSec-WebSocket-Version: 13"
        XCTAssertEqual(WebSocketTransport.HandshakeRequest(upgrade), .upgrade(key: "abc=="))
        XCTAssertEqual(WebSocketTransport.HandshakeRequest("GET /health HTTP/1.1\r\nHost: x"), .health)
        XCTAssertEqual(WebSocketTransport.HandshakeRequest("POST / HTTP/1.1\r\nHost: x"), .invalid)
        XCTAssertEqual(WebSocketTransport.HandshakeRequest("GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13"), .invalid)
    }

    func testFramesRoundTripMaskedAndNotAtEverySize() throws {
        for size in [0, 1, 125, 126, 65535, 65536, 200_000] {
            let payload = (0..<size).map { UInt8($0 & 0xff) }
            for masked in [false, true] {
                var reader = WebSocketTransport.FrameReader()
                let bytes = WebSocketTransport.frame(.binary, payload[...], masked: masked)
                // Arrives in pieces.
                for start in stride(from: 0, to: bytes.count, by: 7000) {
                    XCTAssertNil(try reader.next())
                    reader.append(bytes[start..<min(start + 7000, bytes.count)])
                }
                let frame = try XCTUnwrap(try reader.next())
                XCTAssertEqual(frame.0, .binary)
                XCTAssertEqual(frame.1, payload, "size \(size) masked \(masked)")
                XCTAssertNil(try reader.next())
            }
        }
    }

    func testRejectsReservedBitsAndHugeFrames() {
        var reserved = WebSocketTransport.FrameReader()
        reserved.append([0xC2, 0x00][...])
        XCTAssertThrowsError(try reserved.next())
        var huge = WebSocketTransport.FrameReader()
        huge.append([0x82, 127, 0, 0, 0, 1, 0, 0, 0, 0][...])
        XCTAssertThrowsError(try huge.next())
    }
}
