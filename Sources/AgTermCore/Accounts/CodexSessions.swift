import Foundation

/// Which Codex conversation a run opens, from its arguments and the rollout files.
public enum CodexSessions {
    /// The session `codex resume <id>` or `codex exec resume <id>` reopens. Nil for other runs,
    /// and for `resume --last` or the picker, which don't name one.
    public static func resumed(_ userArgs: [String]) -> String? {
        guard let resume = userArgs.firstIndex(of: "resume") else { return nil }
        return userArgs[(resume + 1)...].first { isSessionID($0) }
    }

    /// Codex session ids are UUIDs.
    static func isSessionID(_ text: String) -> Bool {
        text.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }

    /// The rollout for a session id under `sessions` (`YYYY/MM/DD/rollout-<time>-<id>.jsonl`).
    public static func rollout(in sessions: URL, sessionID: String) -> URL? {
        let suffix = "-\(sessionID.lowercased()).jsonl"
        let fm = FileManager.default
        // Newest days first: a resumed session is usually recent.
        let days = children(sessions).flatMap(children).flatMap(children)
        for day in days {
            if let name = ((try? fm.contentsOfDirectory(atPath: day.path)) ?? [])
                .first(where: { $0.hasPrefix("rollout-") && $0.lowercased().hasSuffix(suffix) }) {
                return day.appendingPathComponent(name)
            }
        }
        return nil
    }

    private static func children(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.allSatisfy(\.isNumber) }.sorted(by: >).map { dir.appendingPathComponent($0, isDirectory: true) }
    }
}
