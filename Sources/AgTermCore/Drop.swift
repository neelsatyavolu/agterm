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
