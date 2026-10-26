import SwiftTerm

public extension BufferLine {
    /// The row as text, trailing blanks trimmed. Cells nothing was written to read as spaces, not
    /// NUL: TUIs like Claude Code step the cursor over gaps instead of printing spaces.
    func plainText() -> String {
        translateToString(trimRight: true, skipNullCellsFollowingWide: true) { cell in
            let character = cell.getCharacter()
            return character == "\0" ? " " : character
        }
    }
}
