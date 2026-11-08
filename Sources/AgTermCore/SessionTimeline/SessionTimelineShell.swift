import Foundation

/// Commands in a plain shell tab, read from the prompt marks agterm's zsh integration writes
/// (OSC 133: `A` prompt, `B` input, `C` output). The terminal tags each cell with its role.
public enum SessionTimelineShell {
    /// One terminal row as the timeline needs it.
    public struct Row: Equatable, Sendable {
        /// Has cells of a primary prompt (`A`).
        public var hasPrompt: Bool
        /// The text of the cells you typed (`B`).
        public var input: String
        /// Has cells of command output (`C`).
        public var hasOutput: Bool
        /// Continues the row above (the line wrapped).
        public var isWrapped: Bool

        public init(hasPrompt: Bool = false, input: String = "", hasOutput: Bool = false, isWrapped: Bool = false) {
            self.hasPrompt = hasPrompt
            self.input = input
            self.hasOutput = hasOutput
            self.isWrapped = isWrapped
        }
    }

    /// Every command run at a marked prompt, oldest first. The prompt you're typing at is left
    /// out; `running` says the newest command is still going.
    public static func commands(_ rows: [Row], running: Bool) -> [SessionTimelineTurn] {
        var found: [(row: Int, command: String, end: Int)] = []
        var y = 0
        while y < rows.count {
            guard rows[y].hasPrompt else { y += 1; continue }
            let start = y
            var parts = [rows[y].input]
            y += 1
            // Wrapped rows and continuation lines (PS2) belong to the same command.
            while y < rows.count, !rows[y].hasPrompt, !rows[y].hasOutput, rows[y].isWrapped || !rows[y].input.isEmpty {
                if rows[y].isWrapped { parts[parts.count - 1] += rows[y].input } else { parts.append(rows[y].input) }
                y += 1
            }
            let command = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { found.append((start, command, y)) }
        }
        // The newest was submitted once anything follows it: output, or the next prompt.
        if let last = found.last, !running, !rows[last.end...].contains(where: { $0.hasOutput || $0.hasPrompt }) {
            found.removeLast()
        }
        return found.enumerated().map { i, entry in
            let newest = i == found.count - 1
            return SessionTimelineTurn(id: "shell-\(entry.row)", prompt: entry.command,
                                       status: newest && running ? .running : .done, row: entry.row)
        }
    }
}
