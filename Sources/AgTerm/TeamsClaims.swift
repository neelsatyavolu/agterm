import Foundation

/// The agent sessions that started in agterm, the only ones agterm may report to agmux Teams.
/// Claude Code session ids are recorded as tabs see them (from ~/.claude/sessions/<pid>.json);
/// Codex sessions carry `originator: agterm` in their own header, set by the codex wrapper.
final class TeamsClaims {
    static let shared = TeamsClaims()

    private var claude: [String: Date] = [:]
    private var dirty = false
    private let url = AgentIntegration.supportDir.appendingPathComponent("teams-claims.json")

    private init() {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: [String: Date]].self, from: data) else { return }
        claude = saved["claude"] ?? [:]
    }

    func recordClaude(_ sessionID: String) {
        guard claude[sessionID] == nil else { return }
        claude[sessionID] = Date()
        dirty = true
        save()
    }

    var claudeSessions: Set<String> { Set(claude.keys) }

    private func save() {
        guard dirty else { return }
        dirty = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(["claude": claude]).write(to: url, options: .atomic)
        } catch {
            NSLog("agterm: couldn't save Teams session claims: %@", error.localizedDescription)
        }
    }
}
