import Foundation

/// agterm opened from inside one of its own tabs (`open` from a shell, an agent launching it)
/// inherits that tab's agent session: Claude Code's per-session markers, the tab's id, and the
/// login folder of the agent's account. Passed on to every new tab, they make each Claude there
/// think it is a child of that session (no transcripts, mixed-up status). The app drops them at
/// launch; variables you set yourself stay.
public enum InheritedEnvironment {
    /// Set only inside a running agent or an agterm tab, never by you.
    private static let sessionPrefixes = ["CLAUDE_CODE_"]
    private static let sessionNames: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_PLUGIN_DATA", "CODEX_COMPANION_SESSION_ID",
        "AGTERM_TAB_ID", "AGTERM_ACCOUNT", "AGTERM_BIN",
    ]
    /// Login folders: dropped only when they point into agterm's own account folders.
    private static let loginFolders = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME"]

    /// The variables to drop, if `env` came from an agent session or an agterm tab; else none.
    public static func toDrop(_ env: [String: String], accountsDir: String) -> [String] {
        guard env["CLAUDECODE"] != nil || env["AGTERM_TAB_ID"] != nil else { return [] }
        let accounts = accountsDir.hasSuffix("/") ? accountsDir : accountsDir + "/"
        return env.keys.filter { key in
            sessionNames.contains(key) || sessionPrefixes.contains { key.hasPrefix($0) }
                || (loginFolders.contains(key) && (env[key].map { ($0 + "/").hasPrefix(accounts) } ?? false))
        }.sorted()
    }
}
