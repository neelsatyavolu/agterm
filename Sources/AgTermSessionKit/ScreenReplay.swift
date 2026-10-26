import Foundation
import SwiftTerm

/// What a client is sent on attach so its terminal shows what the session's screen holds.
public enum ScreenReplay {
    /// Scrollback and screen as plain text rows joined by CR LF, trailing blank rows dropped.
    /// Plain text only for now: colors, the alternate screen, modes and the cursor come later.
    public static func bytes(_ terminal: Terminal) -> Data {
        var rows = String(decoding: terminal.getBufferAsData(), as: UTF8.self).components(separatedBy: "\n")
        while rows.last?.isEmpty == true { rows.removeLast() }
        return Data(rows.joined(separator: "\r\n").utf8)
    }
}
