import Foundation

/// One entry of `git worktree list --porcelain`.
public struct WorktreeEntry: Equatable, Sendable {
    public let path: String
    /// Nil when detached.
    public let branch: String?
    /// The repository's own checkout, which can't be removed.
    public let isMain: Bool
    /// Its folder is gone; `git worktree prune` clears it.
    public let prunable: Bool

    public init(path: String, branch: String?, isMain: Bool = false, prunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.prunable = prunable
    }
}

/// Names and places for the worktrees agterm makes: `~/.agterm/worktrees/<repo>/<branch>`,
/// outside the repo so tools scanning it never see a second copy.
public enum WorktreeNames {
    public static let maxBranchLength = 60

    /// A branch name git accepts, from whatever was typed: lowercase words joined by dashes,
    /// slashes kept for groups like `feat/…`. Empty if nothing usable is left.
    public static func branch(_ raw: String) -> String {
        var name = ""
        for ch in raw.lowercased() {
            if ch.isWhitespace || ch == "_" { name.append("-") } else if ch.isASCII, ch.isLetter || ch.isNumber || "-./".contains(ch) { name.append(ch) }
        }
        for (run, single) in [("--", "-"), ("..", "."), ("//", "/")] {
            while name.contains(run) { name = name.replacingOccurrences(of: run, with: single) }
        }
        let parts = name.split(separator: "/").map { part -> String in
            var part = String(part)
            if part.hasSuffix(".lock") { part.removeLast(5) }
            return part.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
        return String(joined.prefix(maxBranchLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
    }

    private static let adjectives = ["amber", "brisk", "calm", "clever", "dusky", "eager", "fleet", "gentle", "humble",
                                     "keen", "lucid", "mellow", "nimble", "plucky", "quiet", "rapid", "steady", "sunny",
                                     "tidy", "vivid", "witty", "zesty"]
    private static let nouns = ["badger", "comet", "crane", "falcon", "fern", "fox", "harbor", "heron", "lark", "maple",
                                "meadow", "otter", "pine", "quill", "raven", "river", "robin", "sparrow", "summit",
                                "thistle", "willow", "wren"]

    /// A short, readable default like `agterm/quiet-fox`.
    public static func suggested(seed: UInt64) -> String {
        let adjective = adjectives[Int(seed % UInt64(adjectives.count))]
        let noun = nouns[Int((seed / UInt64(adjectives.count)) % UInt64(nouns.count))]
        return "agterm/\(adjective)-\(noun)"
    }

    public static func root(home: String) -> String { home + "/.agterm/worktrees" }

    /// Where the worktree for `branch` of the repository at `repo` goes.
    public static func folder(home: String, repo: String, branch: String) -> String {
        root(home: home) + "/" + (repo as NSString).lastPathComponent + "/" + branch.replacingOccurrences(of: "/", with: "-")
    }

    /// A worktree agterm made, which it may offer to remove.
    public static func isManaged(_ path: String, home: String) -> Bool { path.hasPrefix(root(home: home) + "/") }

    public static func parseList(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        for block in output.components(separatedBy: "\n\n") {
            var path: String?, branch: String?, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line.hasPrefix("prunable") { prunable = true }
            }
            guard let path else { continue }
            entries.append(WorktreeEntry(path: path, branch: branch, isMain: entries.isEmpty, prunable: prunable))
        }
        return entries
    }

    /// Ignored local settings a new worktree needs to run like the original: `.env`, `.env.*`
    /// and `.envrc`, up to two folders deep, never inside dependencies. Root files first.
    /// `ignored` is `git ls-files --others --ignored --exclude-standard`.
    public static func envFiles(_ ignored: [String]) -> [String] {
        ignored.filter { path in
            let parts = path.split(separator: "/")
            guard let name = parts.last, !path.hasSuffix("/"), parts.count <= 3, !parts.contains("node_modules") else { return false }
            return name == ".env" || name == ".envrc" || name.hasPrefix(".env.")
        }
        .sorted { a, b in
            let depthA = a.split(separator: "/").count, depthB = b.split(separator: "/").count
            return depthA == depthB ? a < b : depthA < depthB
        }
    }
}
