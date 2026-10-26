import AgTermCore
import AgTermSessionKit
import SwiftTerm

/// Reads a terminal's history back out as text with ANSI colors, so a restored tab looks like it
/// did at quit. The work lives in `ScreenReplay`, shared with the session helper.
enum Scrollback {
    static let maxLines = ScreenReplay.maxLines

    static func capture(_ terminal: Terminal) -> String { ScreenReplay.history(terminal) }

    static func cellColor(_ color: Attribute.Color) -> CellColor { ScreenReplay.cellColor(color) }
}
