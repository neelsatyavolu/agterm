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
