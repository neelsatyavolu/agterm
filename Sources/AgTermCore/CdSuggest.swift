import Foundation

/// Folder suggestions while typing `cd <word>` at a shell prompt: the word is matched against
/// folder names anywhere agterm knows about, so `cd sheafnote` can jump to
/// `~/Documents/GitHub/sheafnote` without typing the path.
public enum CdSuggest {
    public static let limit = 6

    /// The word being typed after `cd`, from the text left of the cursor. Nil when the line isn't
    /// a `cd` or the word is a path (`~/…`, `../…`, `-`), which the shell's own completion handles.
    public static func query(beforeCursor text: String) -> String? {
        guard let match = text.range(of: #"(?:^|[\s;&|(])cd +(\S+)$"#, options: .regularExpression) else { return nil }
        let word = String(text[match].split(separator: " ").last ?? "")
        guard let first = word.first, !"~.-$".contains(first), !word.contains("/") else { return nil }
        return word
    }

    /// Best matches first: exact name, then prefix, then substring, then (only if none of those)
    /// letters in order. Ties go to folders inside `cwd`, then ones visited more, then shallower paths.
    public static func rank(query: String, cwd: String, candidates: [String], visits: [String: Int]) -> [String] {
        let q = query.lowercased()
        var seen = Set<String>()
        let scored: [(path: String, tier: Int, child: Bool, visits: Int, depth: Int)] = candidates.compactMap { path in
            guard path != cwd, seen.insert(path).inserted, let tier = tier(name: (path as NSString).lastPathComponent.lowercased(), query: q) else { return nil }
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
        for character in query {
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
