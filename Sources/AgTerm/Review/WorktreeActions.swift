import AgTermCore
import Foundation

struct WorktreeCreated {
    let path: String
    let branch: String
    /// The repo has `.agterm/worktree-setup.sh`; the new tab runs it before the agent.
    let hasSetupScript: Bool
}

/// What removing a worktree would lose, for the confirmation.
struct WorktreeRemoval {
    let path: String
    let mainRoot: String
    let branch: String?
    let uncommitted: Int
    /// Commits on its branch that its base branch doesn't have; nil when that can't be told.
    let unmerged: Int?
    let base: String?
    /// agterm made this branch for the worktree (rather than checking out one you had).
    let madeByAgterm: Bool

    /// Offer to delete the branch too, ticked, only when nothing on it can be lost.
    var branchSafeToDelete: Bool { madeByAgterm && unmerged == 0 && uncommitted == 0 }
}

/// Makes and removes the worktrees behind worktree tabs. Every function blocks; call them on
/// `GitRunner.writes` (or `reads` for `list`).
enum WorktreeActions {
    static let setupScript = ".agterm/worktree-setup.sh"

    /// The main checkout of the repository `cwd` is in, even from inside one of its worktrees.
    static func mainRoot(_ cwd: String) -> String? {
        let common = GitRunner.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: cwd)
        guard common.ok else { return nil }
        let dir = common.trimmed as NSString
        return dir.lastPathComponent == ".git" ? dir.deletingLastPathComponent : nil
    }

    /// A new worktree for `branch` (made from the current commit if it doesn't exist), with
    /// the source checkout's `.env` files copied in.
    static func create(cwd: String, branch: String) -> Result<WorktreeCreated, GitFailure> {
        guard let main = mainRoot(cwd) else { return .failure("Worktrees need a git repository with a .git folder.") }
        let source = GitRunner.git(["rev-parse", "--show-toplevel"], in: cwd).trimmed
        let folder = WorktreeNames.folder(home: NSHomeDirectory(), repo: main, branch: branch)
        guard !FileManager.default.fileExists(atPath: folder) else { return .failure(GitFailure("\(PathDisplay.folder(folder, home: NSHomeDirectory())) already exists.")) }
        try? FileManager.default.createDirectory(atPath: (folder as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let current = GitRunner.git(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd).trimmed
        let exists = GitRunner.git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: cwd).ok
        let added = GitRunner.git(exists ? ["worktree", "add", folder, branch] : ["worktree", "add", "-b", branch, folder, "HEAD"],
                                  in: cwd, timeout: 120)
        guard added.ok else { return .failure(added.failure) }
        if !exists, current != "HEAD", !current.isEmpty {
            _ = GitRunner.git(["config", "branch.\(branch).agterm-base", current], in: main)
        }
        copyEnvFiles(from: source.isEmpty ? main : source, to: folder)
        let script = FileManager.default.fileExists(atPath: folder + "/" + setupScript)
        return .success(WorktreeCreated(path: folder, branch: branch, hasSetupScript: script))
    }

    /// Ignored settings files (`.env`, `.env.local`, `.envrc`) the new checkout wouldn't have.
    /// `--directory` stops git at ignored folders, so node_modules isn't walked.
    private static func copyEnvFiles(from source: String, to folder: String) {
        let ignored = GitRunner.git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: source)
        let fm = FileManager.default
        for path in WorktreeNames.envFiles(ignored.out.split(separator: "\0").map(String.init)) {
            let target = folder + "/" + path
            guard !fm.fileExists(atPath: target) else { continue }
            try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: source + "/" + path, toPath: target)
        }
    }

    /// The worktrees agterm made for the repository `cwd` is in.
    static func list(_ cwd: String) -> [WorktreeEntry] {
        let out = GitRunner.git(["worktree", "list", "--porcelain"], in: cwd)
        return WorktreeNames.parseList(out.out).filter { !$0.isMain && !$0.prunable && WorktreeNames.isManaged($0.path, home: NSHomeDirectory()) }
    }

    /// The worktree `cwd` is in, if agterm made it, and what removing it would lose.
    static func removal(_ cwd: String) -> WorktreeRemoval? {
        let top = GitRunner.git(["rev-parse", "--show-toplevel"], in: cwd).trimmed
        guard WorktreeNames.isManaged(top, home: NSHomeDirectory()), let main = mainRoot(cwd) else { return nil }
        let branch = GitRunner.git(["rev-parse", "--abbrev-ref", "HEAD"], in: top).trimmed
        let named = branch == "HEAD" || branch.isEmpty ? nil : branch
        let dirty = GitRunner.git(["status", "--porcelain"], in: top).out.split(separator: "\n").count
        let recorded = named.map { GitRunner.git(["config", "--get", "branch.\($0).agterm-base"], in: main).trimmed }.flatMap { $0.isEmpty ? nil : $0 }
        // A branch you had before gets compared with the default branch; unknown if there's none.
        let base = recorded ?? GitActions.defaultBranch(main)
        let unmerged: Int? = base.flatMap { base in
            guard base != named else { return nil }
            let count = GitRunner.git(["rev-list", "--count", "\(base)..HEAD"], in: top)
            return count.ok ? Int(count.trimmed) : nil
        }
        return WorktreeRemoval(path: top, mainRoot: main, branch: named, uncommitted: dirty, unmerged: unmerged, base: base,
                               madeByAgterm: recorded != nil)
    }

    /// Removes the worktree you confirmed. Stops, removing nothing, if it gained changes since you
    /// confirmed (an agent may still be writing). The branch is deleted only if it's merged.
    static func remove(_ removal: WorktreeRemoval, deleteBranch: Bool) -> Result<Void, GitFailure> {
        let status = GitRunner.git(["status", "--porcelain"], in: removal.path)
        guard status.ok else { return .failure(status.failure) }
        let dirty = status.out.split(separator: "\n").count
        guard dirty <= removal.uncommitted else {
            return .failure("Files in the worktree changed after you confirmed, so nothing was removed. Try again to see what would be lost.")
        }
        // --force only to drop the changes you were told about.
        let removed = GitRunner.git(["worktree", "remove"] + (dirty > 0 ? ["--force"] : []) + [removal.path], in: removal.mainRoot, timeout: 120)
        guard removed.ok else { return .failure(removed.failure) }
        _ = GitRunner.git(["worktree", "prune"], in: removal.mainRoot)
        if deleteBranch, let branch = removal.branch {
            // -d refuses a branch with commits that aren't merged, so they can't be lost here.
            let deleted = GitRunner.git(["branch", "-d", branch], in: removal.mainRoot)
            guard deleted.ok else {
                return .failure(GitFailure("The worktree is gone. The branch \(branch) was kept because it has commits that aren't merged."))
            }
        }
        // Leave no empty repo folder behind in ~/.agterm/worktrees.
        let parent = (removal.path as NSString).deletingLastPathComponent
        if (try? FileManager.default.contentsOfDirectory(atPath: parent))?.isEmpty == true { try? FileManager.default.removeItem(atPath: parent) }
        return .success(())
    }
}
