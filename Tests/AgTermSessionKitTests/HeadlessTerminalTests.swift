@testable import AgTermSessionKit
import Foundation
import SwiftTerm
import XCTest

final class HeadlessTerminalTests: XCTestCase {
    private final class NullDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = NullDelegate()

    /// Claude Code and Codex wrap every redraw in synchronized output. The helper's main
    /// queue never runs, so anything the terminal schedules there per toggle is never freed.
    func testSynchronizedOutputTogglesKeepMemoryFlat() {
        let terminal = HostedSession.makeTerminal(cols: 80, rows: 24, delegate: delegate)
        // `\r` keeps the text on one line, so scrollback doesn't grow either.
        let toggle = Array("\u{1b}[?2026h x \u{1b}[?2026l\r".utf8)
        let batch = Array([[UInt8]](repeating: toggle, count: 1_000).joined())
        terminal.feed(buffer: batch[...])
        let before = footprint()
        for _ in 0..<50 { terminal.feed(buffer: batch[...]) }
        let grown = footprint() - before
        XCTAssertLessThan(grown, 4 * 1024 * 1024, "50k synchronized-output toggles grew the footprint by \(grown) bytes")
        XCTAssertFalse(terminal.synchronizedOutputActive)
    }

    func testSynchronizedOutputStillTracksTheMode() {
        let terminal = HostedSession.makeTerminal(cols: 80, rows: 24, delegate: delegate)
        terminal.feed(text: "\u{1b}[?2026h")
        XCTAssertTrue(terminal.synchronizedOutputActive)
        terminal.feed(text: "\u{1b}[?2026l")
        XCTAssertFalse(terminal.synchronizedOutputActive)
    }

    /// This process's physical footprint, as Activity Monitor shows it.
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
