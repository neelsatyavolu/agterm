import Foundation

/// Uncommitted work in a repository: branch, changed files, and line counts.
public struct GitSummary: Equatable, Sendable {
    public var branch: String?
    public var files = 0
    public var added = 0
    public var removed = 0

    public init(branch: String? = nil, files: Int = 0, added: Int = 0, removed: Int = 0) {
        self.branch = branch
        self.files = files
        self.added = added
        self.removed = removed
    }
}

public enum GitStat {
    /// Parses `git diff --shortstat` output.
    public static func parseShortstat(_ output: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for part in output.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }) else { continue }
            if part.contains("insertion") { added = count }
            if part.contains("deletion") { removed = count }
        }
        return (added, removed)
    }

    /// Parses `git status --porcelain -b`: branch from the `##` line, one file per other line.
    public static func parsePorcelain(_ output: String) -> (branch: String?, files: Int) {
        var branch: String?
        var files = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                branch = parseBranch(String(line.dropFirst(3)))
            } else {
                files += 1
            }
        }
        return (branch, files)
    }

    private static func parseBranch(_ header: String) -> String? {
        let noCommits = "No commits yet on "
        if header.hasPrefix(noCommits) { return String(header.dropFirst(noCommits.count)) }
        let name = header.components(separatedBy: "...").first ?? header
        let clean = name.components(separatedBy: " ").first ?? name
        return clean.isEmpty ? nil : clean
    }
}
