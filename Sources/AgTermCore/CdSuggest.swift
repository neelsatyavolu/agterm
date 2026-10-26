import Foundation

/// Folder suggestions while typing `cd <word>` at a shell prompt: the word is matched against
/// folder names anywhere agterm knows about, so `cd sheafnote` can jump to
/// `~/Documents/GitHub/sheafnote` without typing the path.
public enum CdSuggest {
    public static let limit = 6

    /// Everything typed after `cd`, as typed (`show resources`, `show\ res`, `"show res`), from the
    /// text left of the cursor. Nil when the line isn't a `cd`, another command follows it, or the
    /// word is a path (`~/…`, `../…`, `-`), which the shell's own completion handles.
    public static func query(beforeCursor text: String) -> String? {
        guard let match = text.range(of: #"(?:^|[\s;&|(])cd +([^;&|<>`$()]+)$"#, options: .regularExpression) else { return nil }
        // The match starts at `cd` or the one character before it; what follows `cd` and its spaces.
        let typed = String(text[match].drop { $0 != "c" }.dropFirst(2).drop { $0 == " " })
        let name = unescaped(typed)
        guard let first = name.first, !"~.-$".contains(first), !name.contains("/") else { return nil }
        return typed
    }

    /// The folder name `typed` spells: opening quote and backslash escapes dropped, outer spaces trimmed.
    private static func unescaped(_ typed: String) -> String {
        let unquoted = typed.first == "\"" || typed.first == "'" ? typed.dropFirst() : Substring(typed)
        return unquoted.replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// `-` and `_` read as spaces, so `show resources` finds `Show Resources`, `show-resources`
    /// and `show_resources`.
    private static func searchTerm(_ typed: String) -> String {
        normalized(unescaped(typed))
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// Best matches first: exact name, then prefix, then substring, then (only if none of those)
    /// letters in order. Ties go to folders inside `cwd`, then ones visited more, then shallower paths.
    public static func rank(query: String, cwd: String, candidates: [String], visits: [String: Int]) -> [String] {
        let q = searchTerm(query)
        var seen = Set<String>()
        let scored: [(path: String, tier: Int, child: Bool, visits: Int, depth: Int)] = candidates.compactMap { path in
            guard path != cwd, seen.insert(path).inserted, let tier = tier(name: normalized((path as NSString).lastPathComponent), query: q) else { return nil }
            return (path, tier, (path as NSString).deletingLastPathComponent == cwd, visits[path] ?? 0, path.split(separator: "/").count)
        }
        // Letters-in-order matches are noise once any name actually contains the word.
        let loose = 3
        let kept = scored.contains { $0.tier < loose } ? scored.filter { $0.tier < loose } : scored
        return kept.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.child != b.child { return a.child }
            if a.visits != b.visits { return a.visits > b.visits }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path < b.path
        }.prefix(limit).map(\.path)
    }

    private static func tier(name: String, query: String) -> Int? {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        var rest = Substring(name)
        for character in query where character != " " {
            guard let index = rest.firstIndex(of: character) else { return nil }
            rest = rest[rest.index(after: index)...]
        }
        return 3
    }

    /// The path as it's typed at the prompt: home as `~`, shell-special characters escaped.
    public static func display(_ path: String, home: String) -> String {
        var shown = path
        if path == home {
            return "~"
        } else if path.hasPrefix(home + "/") {
            shown = "~" + path.dropFirst(home.count)
        }
        let special = Set(#" '"\()&;|$`!*?[]{}<>#"#)
        return shown.reduce(into: "") { out, character in
            if special.contains(character) { out.append("\\") }
            out.append(character)
        }
    }

    /// Backspaces over the typed word, then the replacement.
    public static func keystrokes(replacing word: String, with text: String) -> [UInt8] {
        Array(repeating: 0x7F, count: word.count) + Array(text.utf8)
    }
}
