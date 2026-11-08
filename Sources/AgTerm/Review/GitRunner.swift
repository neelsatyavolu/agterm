import AgTermCore
import Foundation

/// Why a git step failed, in words for an alert.
struct GitFailure: Error, ExpressibleByStringLiteral {
    let message: String
    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { message = value }
}

/// Runs `git` and `gh` for the review tools. Call off the main thread: every call waits.
/// Prompts are turned off so a missing credential fails instead of hanging.
enum GitRunner {
    struct Output {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// The last lines git or gh printed on failure, for an alert.
        var failure: GitFailure {
            let lines = (err + "\n" + out).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return GitFailure(lines.suffix(3).joined(separator: "\n"))
        }
    }

    /// Serializes changes (commit, push, worktree add) so two clicks can't race in one repo.
    static let writes = DispatchQueue(label: "agterm.review.writes", qos: .userInitiated)
    /// Reads (diffs, status) run side by side.
    static let reads = DispatchQueue(label: "agterm.review.reads", qos: .userInitiated, attributes: .concurrent)

    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 30) -> Output {
        run("/usr/bin/git", args, in: dir, timeout: timeout)
    }

    /// Found once; the first look waits for your shell's PATH, so on the main thread check
    /// `QuickCommandRunner.shared.isReady` first.
    static var ghPath: String? { resolvedGh }
    private static let resolvedGh = QuickCommandRunner.shared.executable("gh")

    static func gh(_ args: [String], in dir: String, timeout: TimeInterval = 60) -> Output {
        guard let gh = ghPath else { return Output(status: 127, out: "", err: "GitHub CLI (gh) isn't installed.") }
        return run(gh, args, in: dir, timeout: timeout)
    }

    private static func run(_ executable: String, _ args: [String], in dir: String, timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        // Hooks (husky, lint-staged) need the PATH your shell has, not the Dock's.
        env["PATH"] = QuickCommandRunner.shared.searchPath
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        switch QuickCommandRunner.execute(process, timeout: timeout) {
        case let .exited(status, out, err):
            return Output(status: status, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
        case .timedOut:
            return Output(status: -1, out: "", err: "\((executable as NSString).lastPathComponent) took longer than \(Int(timeout)) seconds.")
        case .cancelled:
            return Output(status: -1, out: "", err: "Cancelled.")
        case let .couldNotStart(error):
            return Output(status: -1, out: "", err: error.localizedDescription)
        }
    }
}
