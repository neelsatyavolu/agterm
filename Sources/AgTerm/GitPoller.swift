import AgTermCore
import Foundation

/// Runs `git` off the main thread. One request per folder at a time.
final class GitPoller {
    private let queue = DispatchQueue(label: "agterm.git", qos: .utility, attributes: .concurrent)
    private var inFlight = Set<String>()

    func refresh(path: String, completion: @escaping (GitSummary?) -> Void) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        queue.async {
            let summary = Self.summary(at: path)
            DispatchQueue.main.async {
                self.inFlight.remove(path)
                completion(summary)
            }
        }
    }

    private static func summary(at path: String) -> GitSummary? {
        // --no-optional-locks keeps us from fighting an agent for .git/index.lock.
        guard let status = run(["--no-optional-locks", "-C", path, "status", "--porcelain", "-b"]) else { return nil }
        let porcelain = GitStat.parsePorcelain(status)
        let lines = GitStat.parseShortstat(run(["--no-optional-locks", "-C", path, "diff", "HEAD", "--shortstat"]) ?? "")
        return GitSummary(branch: porcelain.branch, files: porcelain.files, added: lines.added, removed: lines.removed)
    }

    // MARK: What an agent changed

    /// The working tree when an agent started. `git stash create` records uncommitted changes
    /// as a commit object without touching the tree or the stash list.
    struct AgentBaseline {
        let root: String
        let commit: String
        let untracked: Set<String>
    }

    /// Git's well-known empty tree, the baseline for a repo with no commits yet.
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    func baseline(path: String, completion: @escaping (AgentBaseline?) -> Void) {
        queue.async {
            let result = Self.makeBaseline(at: path)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func agentDiff(_ baseline: AgentBaseline, completion: @escaping ((added: Int, removed: Int)?) -> Void) {
        let key = "agent:" + baseline.root
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        queue.async {
            let result = Self.diff(since: baseline)
            DispatchQueue.main.async {
                self.inFlight.remove(key)
                completion(result)
            }
        }
    }

    private static func makeBaseline(at path: String) -> AgentBaseline? {
        guard let root = run(["-C", path, "rev-parse", "--show-toplevel"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else { return nil }
        let stash = run(["--no-optional-locks", "-C", root, "stash", "create"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = run(["-C", root, "rev-parse", "--verify", "-q", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let commit = !stash.isEmpty ? stash : (!head.isEmpty ? head : emptyTree)
        return AgentBaseline(root: root, commit: commit, untracked: untrackedFiles(root))
    }

    private static func diff(since baseline: AgentBaseline) -> (added: Int, removed: Int)? {
        guard let stat = run(["--no-optional-locks", "-C", baseline.root, "diff", baseline.commit, "--shortstat"]) else { return nil }
        var (added, removed) = GitStat.parseShortstat(stat)
        // Files the agent created aren't tracked yet, so git diff doesn't see them.
        for file in untrackedFiles(baseline.root).subtracting(baseline.untracked) {
            let url = URL(fileURLWithPath: baseline.root).appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                  let data = try? Data(contentsOf: url) else { continue }
            added += LineCount.of(data)
        }
        return (added, removed)
    }

    private static func untrackedFiles(_ root: String) -> Set<String> {
        guard let out = run(["--no-optional-locks", "-C", root, "ls-files", "--others", "--exclude-standard", "-z"]) else { return [] }
        return Set(out.split(separator: "\0").map(String.init))
    }

    /// Returns stdout, or nil when git fails (not a repo, git missing).
    private static func run(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
