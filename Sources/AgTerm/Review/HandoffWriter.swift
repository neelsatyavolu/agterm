import AgTermCore
import Foundation

/// Hands a tab's conversation to another agent: writes the brief next to the repo's git data
/// (or under ~/.agterm when there's no repo) and returns the command that starts the new agent on it.
enum HandoffWriter {
    enum Failure: Error {
        case noAgent
        case couldNotWrite(String)

        var message: String {
            switch self {
            case .noAgent: "There's no agent running in this tab to hand off."
            case let .couldNotWrite(detail): "Couldn't save the handoff notes: \(detail)"
            }
        }
    }

    /// Briefs kept per folder; older ones are deleted when a new one is written.
    static let keep = 20
    static let maxCharacters = 40_000

    /// `completion` gets the command line to type in a new tab in `session.cwd`; it runs on the main queue.
    static func prepare(_ session: TerminalSession, to target: HandoffTarget,
                        completion: @escaping (Result<String, Failure>) -> Void) {
        guard let agent = session.agentName else { return completion(.failure(.noAgent)) }
        // Read the session on the main thread; everything after is files.
        let cwd = session.cwd, branch = session.git?.branch
        let claudeID = session.claudeSessionID, started = session.agentStartedAt
        let screen = session.recentText(rows: 600)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Failure>
            do {
                let text = brief(agent: agent, cwd: cwd, branch: branch, claudeID: claudeID, started: started, screen: screen)
                let path = try write(text, cwd: cwd, from: agent, to: target)
                result = .success(target.commandLine(prompt: Handoff.prompt(briefPath: path, fromAgent: agent)))
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.couldNotWrite(error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func brief(agent: String, cwd: String, branch: String?, claudeID: String?, started: Date?, screen: String) -> String {
        let entries: [MobileTimelineEntry]? = {
            if agent == "claude", let claudeID, let url = TranscriptDiff.claudeTranscript(claudeID),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return RemoteTimeline.claude(transcript: text)
            }
            if agent == "codex", let started, let url = TranscriptDiff.codexRollout(cwd: cwd, since: started),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return RemoteTimeline.codex(rollout: text)
            }
            return nil
        }()
        if let entries, entries.contains(where: { $0.kind == "user" }) {
            return Handoff.brief(entries: entries, fromAgent: agent, cwd: cwd, branch: branch, maxCharacters: maxCharacters)
        }
        return Handoff.brief(screen: screen, fromAgent: agent, cwd: cwd, branch: branch, maxCharacters: maxCharacters)
    }

    /// Writes the brief readable only by you and returns its path.
    private static func write(_ brief: String, cwd: String, from agent: String, to target: HandoffTarget) throws -> String {
        let dir = folder(cwd: cwd)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let file = dir.appendingPathComponent("\(formatter.string(from: Date()))-\(agent)-to-\(target.rawValue).md")
            guard fm.createFile(atPath: file.path, contents: Data(brief.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw Failure.couldNotWrite("\(file.path) couldn't be created.")
            }
            prune(dir)
            return file.path
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
    }

    /// `<git common dir>/agterm/handoffs` inside a repo (shared by its worktrees, never committed),
    /// else ~/.agterm/handoffs.
    private static func folder(cwd: String) -> URL {
        if let common = git(["-C", cwd, "rev-parse", "--git-common-dir"]) {
            let base = common.hasPrefix("/") ? URL(fileURLWithPath: common) : URL(fileURLWithPath: cwd).appendingPathComponent(common)
            return base.standardizedFileURL.appendingPathComponent("agterm/handoffs", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agterm/handoffs", isDirectory: true)
    }

    /// Keeps the newest `keep` briefs (names sort by time).
    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        let briefs = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        for name in briefs.dropLast(keep) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    private static func git(_ args: [String]) -> String? {
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
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
