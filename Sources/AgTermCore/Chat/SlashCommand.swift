import Foundation

/// A command the chat's `/` menu offers: one the agent has built in, or a skill, custom command
/// or plugin command it reads from disk.
public struct SlashCommand: Equatable, Sendable {
    /// Without the slash: `model`, `vercel:workflow`, `prompts:release`.
    public let name: String
    public let about: String

    public init(_ name: String, _ about: String) {
        self.name = name
        self.about = about
    }
}

/// What the composer's text asks the `/` menu for, and the commands that match it.
public enum SlashMenu {
    /// The most rows the menu shows; the rest are reached by moving the selection.
    public static let maxRows = 8

    /// The command name being typed: the text after a leading `/`, while there's no space or
    /// newline yet. Nil when the text isn't a command in progress.
    public static func query(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return String(rest)
    }

    /// Commands for `query`, best first: names that start with it (or whose part after a
    /// plugin's `name:` does), then fuzzy matches on the name. An empty query lists every
    /// command in the catalog's order.
    public static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard !query.isEmpty else { return commands }
        let lower = query.lowercased()
        let whole = commands.filter { $0.name.lowercased().hasPrefix(lower) }
        let part = commands.filter {
            !$0.name.lowercased().hasPrefix(lower) && $0.name.split(separator: ":").last?.lowercased().hasPrefix(lower) == true
        }
        let prefixed = whole + part
        let names = Set(prefixed.map(\.name))
        let fuzzy = FuzzyMatch.rank(query, commands.filter { !names.contains($0.name) }) { $0.name }.map(\.item)
        return prefixed + fuzzy
    }

    /// The text a chosen command leaves in the box, ready for arguments.
    public static func completion(_ command: SlashCommand) -> String { "/\(command.name) " }
}
