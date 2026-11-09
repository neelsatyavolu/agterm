import Foundation

/// A file change an agent made through its shell instead of its edit tool.
public struct ShellEdit: Equatable, Sendable {
    /// "Write", "Append" or "Edit".
    public let verb: String
    /// As the command names it; empty when the script doesn't say.
    public let path: String
    public let additions: Int
    public let deletions: Int
    /// At most `ShellEdits.maxLines`.
    public let lines: [ChatDiffLine]

    init(verb: String, path: String, lines: [ChatDiffLine]) {
        self.verb = verb
        self.path = path
        additions = lines.filter { $0.kind == .added }.count
        deletions = lines.filter { $0.kind == .removed }.count
        self.lines = Array(lines.prefix(ShellEdits.maxLines))
    }
}

/// Reads file changes out of a shell command's text, so the chat can show them as diffs:
/// `cat > file <<'EOF'` heredocs, and Python heredoc scripts that `.replace(old, new)` in a
/// file. The diff is what the command asked for; nothing checks that the text was found.
enum ShellEdits {
    static let maxLines = 400

    static func parse(_ command: String) -> [ShellEdit] {
        guard command.containsBytes("<<") else { return [] }
        let lines = command.components(separatedBy: "\n")
        var edits: [ShellEdit] = []
        var index = 0
        while index < lines.count {
            let head = lines[index]
            index += 1
            guard head.containsBytes("<<"), let open = first(heredoc, in: head), let word = group(2, of: open, in: head),
                  let end = lines[index...].firstIndex(where: { $0 == word || $0.trimmingCharacters(in: .whitespaces) == word }) else { continue }
            let body = Array(lines[index..<end])
            index = end + 1
            if let (verb, path) = writeTarget(head) {
                edits.append(ShellEdit(verb: verb, path: path, lines: body.map { ChatDiffLine(kind: .added, text: $0) }))
            } else if first(python, in: head) != nil {
                edits += pythonEdits(body.joined(separator: "\n"))
            }
        }
        return edits
    }

    // MARK: Heredoc writes

    private static let word = #"("[^"]+"|'[^']+'|[^\s<>|;&()]+)"#
    private static let heredoc = regex(#"(?<!<)<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1"#)
    private static let python = regex(#"\bpython[0-9.]*\b[^|;&<]*<<"#)
    /// `cat > f <<EOF`, `cat <<EOF > f` and `tee [-a] f <<EOF`.
    private static let catThenFile = regex(#"\bcat\s*(>>?)\s*"# + word + #"\s*<<"#)
    private static let catHeredocThenFile = regex(#"\bcat\s*<<-?\s*['"]?\w+['"]?\s*(>>?)\s*"# + word)
    private static let tee = regex(#"\btee\s+(-a\s+)?"# + word + #"[^|;&<]*<<"#)

    private static func writeTarget(_ head: String) -> (verb: String, path: String)? {
        for pattern in [catThenFile, catHeredocThenFile] {
            guard let match = first(pattern, in: head), let path = group(2, of: match, in: head) else { continue }
            return (group(1, of: match, in: head) == ">>" ? "Append" : "Write", unquoted(path))
        }
        guard let match = first(tee, in: head), let path = group(2, of: match, in: head) else { return nil }
        return (group(1, of: match, in: head) == nil ? "Write" : "Append", unquoted(path))
    }

    private static func unquoted(_ word: String) -> String {
        word.count >= 2 && (word.hasPrefix("\"") || word.hasPrefix("'")) ? String(word.dropFirst().dropLast()) : word
    }

    // MARK: Python scripts

    private static let literal = #"[rRbBuUfF]{0,2}(?:'''(?:[^\\]|\\.)*?'''|"""(?:[^\\]|\\.)*?"""|'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")"#
    private static let argument = "(" + literal + #"|[A-Za-z_]\w*)"#
    private static let replaceCall = regex(#"\.replace\(\s*"# + argument + #"\s*,\s*"# + argument + #"\s*(?:,\s*\d+\s*)?\)"#)
    /// `name = 'literal'` up to the end of the statement.
    private static let assignment = regex(#"(?m)(?:^|;)[ \t]*([A-Za-z_]\w*)[ \t]*=[ \t]*("# + literal + #")(?=[ \t]*(?:$|#|;))"#)
    private static let pathCall = regex(#"\b(?:Path|open)\(\s*("# + literal + ")")

    /// One edit per file, from the `.replace(old, new)` calls whose arguments are string
    /// literals or names assigned one.
    private static func pythonEdits(_ script: String) -> [ShellEdit] {
        guard script.containsBytes(".replace(") else { return [] }
        let assignments = matches(assignment, in: script).compactMap { match -> (name: String, value: String, at: Int)? in
            guard let name = group(1, of: match, in: script), let value = group(2, of: match, in: script) else { return nil }
            return (name, pythonString(value), match.range.location)
        }
        func value(_ argument: String, before location: Int) -> String? {
            if argument.hasSuffix("'") || argument.hasSuffix("\"") { return pythonString(argument) }
            return assignments.last { $0.name == argument && $0.at < location }?.value
        }
        var replaced = Set<String>()
        let pairs = matches(replaceCall, in: script).compactMap { match -> (old: String, new: String, at: Int)? in
            guard let a = group(1, of: match, in: script), let b = group(2, of: match, in: script),
                  let old = value(a, before: match.range.location), let new = value(b, before: match.range.location), old != new else { return nil }
            replaced.formUnion([a, b])
            return (old, new, match.range.location)
        }
        guard !pairs.isEmpty else { return [] }

        // The file is the nearest path named before the call: `Path("…")`, `open("…")` or `p = "…"`.
        var paths = matches(pathCall, in: script).compactMap { match in
            group(1, of: match, in: script).map { (value: pythonString($0), at: match.range.location) }
        }
        paths += assignments.filter { !replaced.contains($0.name) && looksLikePath($0.value) }.map { ($0.value, $0.at) }
        paths.sort { $0.at < $1.at }

        var order: [String] = []
        var lines: [String: [ChatDiffLine]] = [:]
        for pair in pairs {
            let path = (paths.last { $0.at < pair.at } ?? paths.first)?.value ?? ""
            if lines[path] == nil { order.append(path) }
            lines[path, default: []] += diff(pair.old, pair.new)
        }
        return order.map { ShellEdit(verb: "Edit", path: $0, lines: lines[$0] ?? []) }
    }

    private static func looksLikePath(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 400, !text.contains(where: \.isWhitespace) else { return false }
        return text.contains("/") || text.range(of: #"\.\w{1,8}$"#, options: .regularExpression) != nil
    }

    /// Removed then added lines, with the lines both share at the start and end as context.
    static func diff(_ old: String, _ new: String) -> [ChatDiffLine] {
        let a = rustLines(old), b = rustLines(new)
        var head = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < min(a.count, b.count) - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        return a[..<head].map { ChatDiffLine(kind: .context, text: $0) }
            + a[head..<(a.count - tail)].map { ChatDiffLine(kind: .removed, text: $0) }
            + b[head..<(b.count - tail)].map { ChatDiffLine(kind: .added, text: $0) }
            + a[(a.count - tail)...].map { ChatDiffLine(kind: .context, text: $0) }
    }

    /// A Python string literal's value: quotes and prefix off, the common escapes read.
    static func pythonString(_ literal: String) -> String {
        let prefix = literal.prefix { $0 != "'" && $0 != "\"" }
        let quoted = literal.dropFirst(prefix.count)
        let quotes = quoted.hasPrefix("'''") || quoted.hasPrefix("\"\"\"") ? 3 : 1
        guard quoted.count >= 2 * quotes else { return String(quoted) }
        let body = quoted.dropFirst(quotes).dropLast(quotes)
        guard !prefix.contains(where: { $0 == "r" || $0 == "R" }), body.contains("\\") else { return String(body) }
        var out = ""
        var escaped = false
        for character in body {
            guard escaped else {
                if character == "\\" { escaped = true } else { out.append(character) }
                continue
            }
            escaped = false
            switch character {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\", "'", "\"": out.append(character)
            case "\n": break
            default: out.append("\\"); out.append(character)
            }
        }
        return out
    }

    // MARK: Regex

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}
