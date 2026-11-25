import Foundation

/// Escapes a path the way Terminal.app does when you drop a file: a backslash before each
/// character the shell would otherwise interpret.
public enum ShellEscape {
    private static let special = Set(#" '"\$`!#&;|<>()[]{}*?~=,^"#)

    public static func path(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for ch in path {
            if special.contains(ch) || ch == "\t" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// One argument of a command typed into a shell. A backslash can't carry a newline (the
    /// shell would run the command there), so multi-line text goes in single quotes instead,
    /// which zsh, bash and fish all read as one word.
    public static func argument(_ text: String) -> String {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" }) else { return path(text) }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What a drop types into the terminal.
public enum DropText {
    /// Escaped paths separated by spaces, with a trailing space so you can keep typing.
    public static func forPaths(_ paths: [String]) -> String {
        paths.isEmpty ? "" : paths.map(ShellEscape.path).joined(separator: " ") + " "
    }

    /// Wraps text in bracketed-paste markers when the program asked for them, so editors and
    /// agent CLIs treat a drop as one paste (Claude Code then attaches dropped image paths).
    public static func wrap(_ text: String, bracketed: Bool) -> String {
        bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
    }
}
