import Foundation

/// What a switched Claude Code login must not inherit, and what it must.
public enum ClaudeAuthEnv {
    /// Variables that pick a login, API key or gateway (the same list agmux clears), so a
    /// session on another account really uses that account.
    public static let keys = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_SESSION_ACCESS_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
        "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_GATEWAY", "CLAUDE_CODE_SIMPLE",
        "CLAUDE_CODE_GATEWAY_TOKEN", "CLAUDE_CODE_GATEWAY_HINT_HEADERS", "CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR",
        "ANTHROPIC_AWS_API_KEY", "ANTHROPIC_AWS_BASE_URL",
        "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_BEDROCK_MANTLE_BASE_URL",
        "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_AUTH_TOKEN", "ANTHROPIC_FOUNDRY_BASE_URL",
        "ANTHROPIC_GOOGLE_CLOUD_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        "ANTHROPIC_IDENTITY_TOKEN", "ANTHROPIC_IDENTITY_TOKEN_FILE",
    ]

    /// Codex equivalents.
    public static let codexKeys = ["OPENAI_API_KEY", "CODEX_API_KEY"]

    private static let sharedKeys: Set<String> = [
        "mcpServers", "projects", "hasCompletedOnboarding", "lastOnboardingVersion", "lastReleaseNotesSeen",
        "theme", "editorMode", "verbose", "autoUpdates", "autoUpdatesProtectedForNative", "installMethod",
        "shiftEnterKeyBindingInstalled", "hasUsedBackslashReturn", "bypassPermissionsModeAccepted",
        "hasAcknowledgedCostThreshold", "githubRepoPaths", "tipsHistory", "migrationVersion", "showSpinnerTree",
        "diffSidebarOpen", "deepLinkTerminal",
    ]

    /// Keys of ~/.claude.json copied into a switched login's own: onboarding done, trusted
    /// folders, MCP servers and dismissed notices. Never the account, its plan or caches.
    public static func sharedStateKey(_ key: String) -> Bool {
        sharedKeys.contains(key) || key.hasPrefix("hasSeen") || key.hasPrefix("hasShown") || key.hasSuffix("MigrationComplete")
            || key.hasSuffix("CalloutDismissed") || key.hasSuffix("CalloutV2Dismissed")
    }
}

public enum CodexConfig {
    /// Your config.toml for another login: its token in that login's own auth.json (not the
    /// Keychain, which every login would share), and the session catalog kept in your own
    /// ~/.codex so `codex resume` finds every conversation.
    public static func forAccount(_ toml: String, sqliteHome: String) -> String {
        func key(_ line: String) -> String {
            line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        // A provider's own key would bill that key instead of this login.
        let secrets: Set<String> = ["api_key", "experimental_bearer_token", "bearer_token"]
        let lines = toml.components(separatedBy: "\n").filter { !secrets.contains(key($0)) }
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        let overridden: Set<String> = ["cli_auth_credentials_store", "sqlite_home"]
        let top = lines[..<firstTable].filter { !overridden.contains(key($0)) }
        let escaped = sqliteHome.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return (["# Written by agterm for a second Codex login; changes are replaced at each launch.",
                 #"cli_auth_credentials_store = "file""#, "sqlite_home = \"\(escaped)\""] + top + lines[firstTable...])
            .joined(separator: "\n")
    }

}
