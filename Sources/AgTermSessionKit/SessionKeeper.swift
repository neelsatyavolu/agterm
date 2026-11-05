import AgTermCore
import Foundation

/// One session as a cloud machine keeps it across a stop: its shell, folder and size, its screen,
/// and the command that brings back the agent it was running.
struct KeptSession: Codable, Equatable {
    var id: String
    var request: SpawnRequest
    var screen: Data
    var resume: String?
}

/// A cloud machine stops when nobody has used it for a while (`--idle-stop`), or when Fly stops
/// it. The helper saves its sessions to the user's volume first, and starts them again with the
/// same ids when the machine boots, so the Mac's tabs reattach to them as if nothing happened.
enum SessionKeeper {
    /// The command that resumes the agent in the foreground, if it is one that can resume.
    static func resumeCommand(_ info: ForegroundInfo) -> String? {
        guard !info.isShell else { return nil }
        if let claude = AgentResume.commandLine(argv: info.argv, claudeSessionID: info.claudeSessionID) { return claude }
        if let id = info.codexSessionID,
           let codex = info.argv.firstIndex(where: { ($0 as NSString).lastPathComponent.hasPrefix("codex") }) {
            return AgentResume.codexCommandLine(userArgs: Array(info.argv[(codex + 1)...]), sessionID: id)
        }
        return AgentCatalog.agent(argv: info.argv).flatMap { AgentResume.continueCommandLine(agent: $0, argv: info.argv) }
    }

    static func save(_ sessions: [KeptSession], to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !sessions.isEmpty, let data = try? JSONEncoder().encode(sessions) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: [.atomic])
        chmod(path, 0o600)
    }

    /// The saved sessions, once: the file is removed, so a crash right after can't bring them back twice.
    static func take(from path: String) -> [KeptSession] {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return (try? JSONDecoder().decode([KeptSession].self, from: data)) ?? []
    }
}
