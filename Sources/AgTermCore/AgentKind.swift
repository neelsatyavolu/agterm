import Foundation

/// The coding-agent CLIs agterm knows: how to recognise them on a tab, start them from the
/// menu, and run them without permission prompts when the CLI has a flag for that.
public struct AgentKind: Hashable, Sendable {
    /// Short name, also the settings key and the name tabs report (e.g. "claude").
    public let id: String
    public let title: String
    /// Command names; the first is what agterm types to start it.
    public let commands: [String]
    /// The flag that turns permission prompts off, or nil if the CLI has none.
    public let bypassFlags: [String]?
    /// Subcommands that don't start a session, so they get no extra flags.
    let utilityCommands: Set<String>
    /// Flags you already chose a permission mode with; agterm leaves those runs alone.
    let permissionFlags: Set<String>

    public var command: String { commands[0] }

    init(_ id: String, _ title: String, commands: [String]? = nil, bypass: [String]? = nil,
         utility: Set<String> = [], permission: Set<String> = []) {
        self.id = id
        self.title = title
        self.commands = commands ?? [id]
        bypassFlags = bypass
        utilityCommands = utility
        permissionFlags = permission.union(bypass.map { [$0[0]] } ?? [])
    }

    public static let claude = AgentKind(
        "claude", "Claude Code", bypass: ["--dangerously-skip-permissions"],
        utility: AgentLaunch.claudeSubcommands, permission: ["--permission-mode"])
    public static let codex = AgentKind(
        "codex", "Codex", bypass: ["--dangerously-bypass-approvals-and-sandbox"],
        utility: ["login", "logout", "mcp", "mcp-server", "app-server", "completion", "sandbox", "debug",
                  "apply", "a", "cloud", "features", "help", "update", "doctor", "review"],
        permission: ["--yolo", "--full-auto", "-a", "--ask-for-approval", "-s", "--sandbox"])
    public static let grok = AgentKind(
        "grok", "Grok", bypass: ["--permission-mode", "bypassPermissions"],
        utility: ["clone", "completions", "doctor", "du", "export", "help", "inspect", "leader", "login", "logout",
                  "mcp", "memory", "models", "plugin", "sessions", "setup", "trace", "update", "usage", "version",
                  "worker", "worktree", "wrap"],
        permission: ["--always-approve"])

    /// Roughly the most used coding CLIs. Bypass flags were read from each CLI's --help where it
    /// was installed (Gemini, Antigravity, OpenCode, Cursor, Kimi, Aider); Amp, Qwen Code, Crush
    /// and Copilot's come from their docs. CLIs without such a flag still get status, diffs,
    /// "needs you" and the New Agent Tab menu.
    public static let all: [AgentKind] = [
        .claude, .codex, .grok,
        AgentKind("gemini", "Gemini CLI", bypass: ["--yolo"], utility: ["mcp", "extensions"],
                  permission: ["-y", "--approval-mode"]),
        AgentKind("agy", "Antigravity", bypass: ["--dangerously-skip-permissions"]),
        AgentKind("cursor-agent", "Cursor Agent", bypass: ["--force"], utility: ["login", "logout", "status", "update", "mcp"],
                  permission: ["-f", "--yolo"]),
        AgentKind("opencode", "OpenCode", bypass: ["--auto"],
                  utility: ["completion", "acp", "mcp", "attach", "run", "debug", "providers", "auth", "agent", "upgrade",
                            "uninstall", "serve", "models", "stats", "export", "import", "github", "pr", "session", "web"]),
        AgentKind("kimi", "Kimi Code", bypass: ["--yolo"], permission: ["-y", "--auto"]),
        AgentKind("aider", "Aider", bypass: ["--yes-always"], permission: ["--yes"]),
        AgentKind("amp", "Amp", bypass: ["--dangerously-allow-all"], utility: ["login", "logout", "mcp", "threads", "update"]),
        AgentKind("qwen", "Qwen Code", bypass: ["--yolo"], utility: ["mcp", "extensions"], permission: ["-y", "--approval-mode"]),
        AgentKind("crush", "Crush", bypass: ["--yolo"], utility: ["logs", "update-providers", "run"], permission: ["-y"]),
        AgentKind("copilot", "GitHub Copilot CLI", bypass: ["--allow-all-tools"], utility: ["help"],
                  permission: ["--allow-tool", "--deny-tool", "--allow-all", "--yolo"]),
        AgentKind("droid", "Factory Droid"),
        AgentKind("kilo", "Kilo Code", commands: ["kilo", "kilocode"]),
        AgentKind("cline", "Cline"),
        AgentKind("goose", "Goose"),
        AgentKind("auggie", "Auggie"),
        AgentKind("qodo", "Qodo"),
        AgentKind("kiro", "Kiro CLI", commands: ["kiro-cli"]),
        AgentKind("continue", "Continue", commands: ["cn"]),
        AgentKind("pi", "Pi"),
    ]

    public static func named(_ id: String) -> AgentKind? { all.first { $0.id == id } }

    /// `userArgs` with permission prompts turned off, or nil to run them unchanged.
    public func bypassingPermissions(_ userArgs: [String]) -> [String]? {
        guard let bypassFlags else { return nil }
        if let first = userArgs.first, utilityCommands.contains(first) || first == "-h" || first == "--help"
            || first == "-v" || first == "-V" || first == "--version" { return nil }
        let chosen = userArgs.contains { arg in
            let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            // A short option with its value attached, like -sread-only.
            let short = arg.count > 2 && !arg.hasPrefix("--") ? String(arg.prefix(2)) : name
            return permissionFlags.contains(name) || permissionFlags.contains(short)
        }
        return chosen ? nil : bypassFlags + userArgs
    }
}
