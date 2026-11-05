@testable import AgTermSessionKit
import Foundation
import XCTest

final class LineRPCServerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // sun_path is short, so keep the folder name short too.
        dir = URL(fileURLWithPath: "/tmp/rpc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ path: String, _ line: String) throws -> [String: Any] {
        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        XCTAssertEqual(write(fd, bytes, bytes.count), bytes.count)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    func testAnswersResultsAndErrorsWithTheRequestID() throws {
        let path = dir.appendingPathComponent("s").path
        let server = try LineRPCServer(path: path, queue: .global()) { method, params, reply in
            if method == "echo" { reply(.success(["got": params["text"] ?? ""])) }
            else { reply(.failure(LineRPCServer.Failure("no \(method)"))) }
        }
        defer { server.stop() }
        let ok = try call(path, #"{"id":7,"method":"echo","params":{"text":"hi"}}"#)
        XCTAssertEqual(ok["id"] as? Int, 7)
        XCTAssertEqual((ok["result"] as? [String: Any])?["got"] as? String, "hi")
        let failed = try call(path, #"{"id":8,"method":"nope"}"#)
        XCTAssertEqual((failed["error"] as? [String: Any])?["message"] as? String, "no nope")
        let garbage = try call(path, "not json")
        XCTAssertNotNil(garbage["error"])
    }

    func testAReplyCanComeLaterFromAnotherThread() throws {
        let path = dir.appendingPathComponent("s").path
        let server = try LineRPCServer(path: path, queue: .main) { _, _, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply(.success("late")) }
        }
        defer { server.stop() }
        var answer: [String: Any]?
        let done = expectation(description: "reply")
        DispatchQueue.global().async {
            answer = try? self.call(path, #"{"id":1,"method":"wait"}"#)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(answer?["result"] as? String, "late")
    }

    func testReplacesASocketLeftBehind() throws {
        let path = dir.appendingPathComponent("s").path
        let first = try LineRPCServer(path: path, queue: .global()) { _, _, reply in reply(.success(1)) }
        _ = first // a crashed run leaves the file; don't stop it
        let second = try LineRPCServer(path: path, queue: .global()) { _, _, reply in reply(.success(2)) }
        defer { second.stop() }
        XCTAssertEqual(try call(path, #"{"id":1,"method":"x"}"#)["result"] as? Int, 2)
    }
}
