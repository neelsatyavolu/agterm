import AgTermCore
import Foundation

/// What the diff panel shows for one tab and scope: the files, and what they're compared with.
struct DiffListing: Equatable {
    let root: String
    /// The commit the working tree is compared with.
    let base: String
    /// Said under the scope picker, e.g. "since origin/main".
    let baseLabel: String
    let files: [FileChange]

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

/// Reads diffs with git. Every function blocks; call them on `GitRunner.reads`.
enum DiffLoader {
    /// Rows a single file's diff shows before it's cut.
    static let maxLines = 4000
    /// Larger untracked files are listed but not read.
    static let maxFileBytes = 2_000_000
    /// Untracked files counted line by line; past this they're listed without counts.
    static let maxCountedFiles = 400
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    static func list(cwd: String, scope: DiffScope, baseline: GitPoller.AgentBaseline?) -> Result<DiffListing, DiffError> {
        let top = GitRunner.git(["rev-parse", "--show-toplevel"], in: cwd)
        guard top.ok, !top.trimmed.isEmpty else { return .failure(.notRepo) }
        let root = scope == .agent ? baseline?.root ?? top.trimmed : top.trimmed
        let base: (commit: String, label: String)
        switch scope {
        case .agent:
            guard let baseline else { return .failure(.noSnapshot) }
            base = (baseline.commit, "since the agent started")
        case .uncommitted:
            let head = GitRunner.git(["rev-parse", "--verify", "-q", "HEAD"], in: root)
            base = (head.ok ? "HEAD" : emptyTree, "against the last commit")
        case .branch:
            guard let found = branchBase(root) else { return .failure(.noDefaultBranch) }
            base = found
        }
        let numstat = GitRunner.git(GitDiff.numstatArguments(base: base.commit), in: root)
        guard numstat.ok else { return .failure(.git(numstat.failure.message)) }
        let untracked = GitRunner.git(["ls-files", "--others", "--exclude-standard", "-z"], in: root).out
            .split(separator: "\0").map(String.init)
        let fresh = GitDiff.newUntracked(now: untracked, baseline: scope == .agent ? baseline?.untracked : nil)
        let files = GitDiff.parseNumstat(numstat.out) + fresh.enumerated().map { index, path in
            FileChange(path: path, added: index < maxCountedFiles ? lineCount(root, path) : 0, untracked: true)
        }
        return .success(DiffListing(root: root, base: base.commit, baseLabel: base.label, files: files.sorted { $0.path < $1.path }))
    }

    static func patch(_ listing: DiffListing, _ file: FileChange) -> DiffDocument {
        if file.binary { return DiffDocument(lines: [DiffLine(kind: .note, text: "Binary file")], truncated: false) }
        guard file.untracked else {
            let out = GitRunner.git(GitDiff.patchArguments(base: listing.base, file: file), in: listing.root)
            return GitDiff.parsePatch(out.out, maxLines: maxLines)
        }
        let url = URL(fileURLWithPath: listing.root).appendingPathComponent(file.path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileBytes,
              let data = try? Data(contentsOf: url) else {
            return DiffDocument(lines: [DiffLine(kind: .note, text: "Too large to show")], truncated: false)
        }
        if data.prefix(8000).contains(0) { return DiffDocument(lines: [DiffLine(kind: .note, text: "Binary file")], truncated: false) }
        return GitDiff.newFile(String(decoding: data, as: UTF8.self), maxLines: maxLines)
    }

    /// The merge base with the branch this one came from: the base recorded when agterm made
    /// the worktree, else origin's default branch, else a local main or master.
    private static func branchBase(_ root: String) -> (commit: String, label: String)? {
        let branch = GitRunner.git(["rev-parse", "--abbrev-ref", "HEAD"], in: root).trimmed
        let recorded = GitRunner.git(["config", "--get", "branch.\(branch).agterm-base"], in: root).trimmed
        let originHead = GitRunner.git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: root)
        let locals = GitRunner.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root).out
            .split(separator: "\n").map(String.init)
        guard let target = recorded.isEmpty ? GitDiff.defaultBranch(originHead: originHead.ok ? originHead.out : nil, localBranches: locals)
            : recorded else { return nil }
        let base = GitRunner.git(["merge-base", "HEAD", target], in: root)
        guard base.ok, !base.trimmed.isEmpty else { return nil }
        return (base.trimmed, "since \(target)")
    }

    private static func lineCount(_ root: String, _ path: String) -> Int {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileBytes,
              let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) else { return 0 }
        return LineCount.of(data)
    }
}

enum DiffError: Error, Equatable {
    case notRepo, noSnapshot, noDefaultBranch
    case git(String)

    var message: String {
        switch self {
        case .notRepo: "This folder isn't in a git repository."
        case .noSnapshot: "No snapshot for this tab yet. agterm takes one when an agent starts here."
        case .noDefaultBranch: "Couldn't find a main or master branch to compare with."
        case let .git(detail): detail
        }
    }
}
