import Foundation

/// What the diff panel compares the working tree against.
public enum DiffScope: String, CaseIterable, Sendable {
    /// Since the agent in the tab started (a `git stash create` snapshot taken then).
    case agent
    /// Everything not committed yet.
    case uncommitted
    /// Everything on this branch since it left the default branch, committed or not.
    case branch

    public var title: String {
        switch self {
        case .agent: "Agent"
        case .uncommitted: "Uncommitted"
        case .branch: "Branch"
        }
    }

    public var help: String {
        switch self {
        case .agent: "What the agent in this tab changed since it started"
        case .uncommitted: "Every change not committed yet"
        case .branch: "Everything on this branch since it split from the default branch"
        }
    }
}

/// One changed file, from `git diff --numstat`.
public struct FileChange: Equatable, Hashable, Sendable {
    public let path: String
    /// The name before a rename.
    public let oldPath: String?
    public let added: Int
    public let removed: Int
    public let binary: Bool
    /// Not known to git yet; shown as all added.
    public let untracked: Bool

    public init(path: String, oldPath: String? = nil, added: Int = 0, removed: Int = 0,
                binary: Bool = false, untracked: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.added = added
        self.removed = removed
        self.binary = binary
        self.untracked = untracked
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case hunk, context, added, removed, note }
    public let kind: Kind
    public let text: String
    public let old: Int?
    public let new: Int?

    public init(kind: Kind, text: String, old: Int? = nil, new: Int? = nil) {
        self.kind = kind
        self.text = text
        self.old = old
        self.new = new
    }
}

/// One file's diff, cut at a line limit so a huge file can't stall the panel.
public struct DiffDocument: Equatable, Sendable {
    public let lines: [DiffLine]
    public let truncated: Bool

    public init(lines: [DiffLine], truncated: Bool) {
        self.lines = lines
        self.truncated = truncated
    }
}

public enum GitDiff {
    /// Lists changed files against `base` (a commit), working tree included.
    public static func numstatArguments(base: String) -> [String] {
        ["--no-optional-locks", "diff", "--numstat", "-z", "-M", "--no-ext-diff", base]
    }

    /// One file's patch against `base`; a rename passes both names so git pairs them.
    public static func patchArguments(base: String, file: FileChange) -> [String] {
        ["--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "-M", "-U3", base, "--"]
            + [file.oldPath, file.path].compactMap { $0 }
    }

    /// Parses `git diff --numstat -z -M`: `added\tremoved\tpath\0`, or for a rename
    /// `added\tremoved\t\0old\0new\0`. Binary files report `-` for both counts.
    public static func parseNumstat(_ output: String) -> [FileChange] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let parts = tokens[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                i += 1
                continue
            }
            let binary = parts[0] == "-"
            let added = Int(parts[0]) ?? 0, removed = Int(parts[1]) ?? 0
            if parts[2].isEmpty, i + 2 < tokens.count {
                files.append(FileChange(path: tokens[i + 2], oldPath: tokens[i + 1], added: added, removed: removed, binary: binary))
                i += 3
            } else {
                files.append(FileChange(path: String(parts[2]), added: added, removed: removed, binary: binary))
                i += 1
            }
        }
        return files
    }

    /// Turns a unified diff into numbered rows, dropping the file headers.
    public static func parsePatch(_ patch: String, maxLines: Int) -> DiffDocument {
        var lines: [DiffLine] = []
        var old = 0, new = 0, inHunk = false
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") { inHunk = false; continue }
            if !inHunk, line.hasPrefix("Binary files ") {
                lines.append(DiffLine(kind: .note, text: "Binary file"))
                continue
            }
            if line.hasPrefix("@@") {
                (old, new) = hunkStarts(line)
                inHunk = true
            } else if !inHunk || line.isEmpty {
                continue
            }
            guard lines.count < maxLines else { return DiffDocument(lines: lines, truncated: true) }
            switch line.first {
            case "@": lines.append(DiffLine(kind: .hunk, text: line))
            case "+":
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), new: new))
                new += 1
            case "-":
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), old: old))
                old += 1
            case "\\":
                lines.append(DiffLine(kind: .note, text: line.dropFirst().trimmingCharacters(in: .whitespaces)))
            default:
                lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: old, new: new))
                old += 1
                new += 1
            }
        }
        return DiffDocument(lines: lines, truncated: false)
    }

    /// A file git doesn't track yet, shown as one hunk of added lines.
    public static func newFile(_ content: String, maxLines: Int) -> DiffDocument {
        var rows = content.split(separator: "\n", omittingEmptySubsequences: false)
        if rows.last == "" { rows.removeLast() }
        var lines = [DiffLine(kind: .hunk, text: "New file · \(rows.count) line\(rows.count == 1 ? "" : "s")")]
        for (index, row) in rows.enumerated() {
            guard lines.count < maxLines else { return DiffDocument(lines: lines, truncated: true) }
            lines.append(DiffLine(kind: .added, text: String(row), new: index + 1))
        }
        return DiffDocument(lines: lines, truncated: false)
    }

    /// Untracked files the agent created: those that weren't untracked when it started.
    public static func newUntracked(now: [String], baseline: Set<String>?) -> [String] {
        guard let baseline else { return now.sorted() }
        return now.filter { !baseline.contains($0) }.sorted()
    }

    /// The branch a feature branch is compared with: origin's default, else a local main or master.
    /// `originHead` is `git symbolic-ref refs/remotes/origin/HEAD`.
    public static func defaultBranch(originHead: String?, localBranches: [String]) -> String? {
        let head = originHead?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "refs/remotes/"
        if head.hasPrefix(prefix), head.count > prefix.count { return String(head.dropFirst(prefix.count)) }
        return ["main", "master"].first(where: localBranches.contains)
    }

    /// `@@ -12,7 +12,8 @@` → (12, 12).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        func start(_ marker: Character) -> Int {
            guard let word = header.split(separator: " ").first(where: { $0.first == marker }) else { return 0 }
            return Int(word.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}
