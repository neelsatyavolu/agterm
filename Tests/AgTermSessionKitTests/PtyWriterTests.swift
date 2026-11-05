@testable import AgTermSessionKit
import Foundation
import XCTest

final class PtyWriterTests: XCTestCase {
    /// Input a program isn't taking stays counted, and the drain callback fires once it is read.
    func testCountsPendingInputUntilTheReaderCatchesUp() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        let writer = PtyWriter(fd: fds[1])
        let chunk = [UInt8](repeating: 0x61, count: 256 * 1024)
        for _ in 0..<4 { writer.write(chunk[...]) }
        XCTAssertGreaterThan(writer.pendingBytes, 0)

        let drained = expectation(description: "drained")
        writer.whenPending(atMost: 0, on: .main) { drained.fulfill() }
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var total = 0
            while total < chunk.count * 4 {
                let count = read(fds[0], &buffer, buffer.count)
                guard count > 0 else { break }
                total += count
            }
        }
        wait(for: [drained], timeout: 10)
        XCTAssertEqual(writer.pendingBytes, 0)
        writer.close()
    }
}
