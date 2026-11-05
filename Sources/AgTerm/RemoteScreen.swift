import AgTermCore
import AgTermSessionKit
import SwiftTerm

/// A tab's live screen for agterm Remote (see `ScreenCapture`).
extension TerminalSession {
    func screenSnapshot() -> ScreenSnapshot {
        ScreenCapture.snapshot(view.getTerminal(), showsCursor: agentName == nil, theme: Theme.palette.id)
    }

    /// One past the last line in the buffer (SwiftTerm doesn't expose the count).
    static func endRow(_ terminal: Terminal, top: Int) -> Int {
        ScreenCapture.endRow(terminal, top: top)
    }
}
