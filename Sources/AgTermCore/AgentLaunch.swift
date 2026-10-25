import Foundation

/// A project registered in agmux (~/.agmux/agmux.db, table `projects`). agterm reuses agmux's
/// ids so agents in both apps share one project memory.
public struct AgmuxProject: Equatable, Sendable {
    public let id: String
    public let repoPath: String

    public init(id: String, repoPath: String) {
        self.id = id
        self.repoPath = repoPath
    }

    /// The project whose folder contains `cwd`, preferring the deepest one (agmux's rule).
    public static func match(_ cwd: String, in projects: [AgmuxProject]) -> AgmuxProject? {
        projects
            .filter { cwd == $0.repoPath || cwd.hasPrefix($0.repoPath.hasSuffix("/") ? $0.repoPath : $0.repoPath + "/") }
            .max { $0.repoPath.count < $1.repoPath.count }
    }

    /// The environment agmux gives its memory server for this project.
    public func memoryEnv(home: String, sessionID: String) -> [String: String] {
        let data = "\(home)/.agmux/projects/\(id)"
        return [
            "AGMUX_PROJECT_ID": id,
            "AGMUX_MEMORY_STORE": "\(data)/memory.json",
            "AGMUX_HANDOFF_STORE": "\(data)/handoffs.json",
            "AGMUX_MEMORY_MD": "\(repoPath)/.agmux/MEMORY.md",
            "AGMUX_SESSIONS_MD": "\(repoPath)/.agmux/SESSIONS.md",
            "AGMUX_SESSION_ID": sessionID,
        ]
    }
}

public struct MCPServer: Equatable, Sendable {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]

    public init(name: String, command: String, args: [String], env: [String: String]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

/// The extra arguments agterm adds when you start an agent, the same ones agmux passes.
public enum AgentLaunch {
    /// Claude Code subcommands that don't start a session.
    private static let claudeSubcommands: Set<String> = [
        "mcp", "config", "update", "doctor", "install", "migrate-installer", "setup-token", "plugin", "plugins",
        "auth", "login", "logout", "agents", "help",
    ]

    /// Arguments for `claude`, or nil to run it unchanged. Uses no --strict-mcp-config, so the
    /// user's own MCP servers keep working.
    public static func claude(userArgs: [String], servers: [MCPServer], instructions: String) -> [String]? {
        if let first = userArgs.first, claudeSubcommands.contains(first) { return nil }
        guard !servers.isEmpty else { return nil }
        var config: [String: Any] = [:]
        for server in servers {
            config[server.name] = ["command": server.command, "args": server.args, "env": server.env]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": config], options: [.sortedKeys]) else { return nil }
        var args = ["--mcp-config", String(decoding: data, as: UTF8.self)]
        if !instructions.isEmpty, !userArgs.contains("--append-system-prompt") {
            args += ["--append-system-prompt", instructions]
        }
        return args + userArgs
    }

    /// Arguments for `codex`: one `-c mcp_servers.<name>={…}` override per server.
    public static func codex(userArgs: [String], servers: [MCPServer]) -> [String]? {
        guard !servers.isEmpty else { return nil }
        let overrides = servers.flatMap { server -> [String] in
            let args = server.args.map(toml).joined(separator: ", ")
            let env = server.env.sorted { $0.key < $1.key }.map { "\($0.key) = \(toml($0.value))" }.joined(separator: ", ")
            return ["-c", "mcp_servers.\(server.name)={ command = \(toml(server.command)), args = [\(args)], env = { \(env) } }"]
        }
        return overrides + userArgs
    }

    /// MCP server names already in a Codex config.toml, so agterm doesn't add a duplicate.
    public static func codexServerNames(_ toml: String) -> Set<String> {
        var names = Set<String>()
        for line in toml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") else { continue }
            let key = trimmed.dropFirst("[mcp_servers.".count).dropLast()
            let name = key.hasPrefix("\"") ? key.dropFirst().prefix { $0 != "\"" } : key.prefix { $0 != "." }
            names.insert(String(name))
        }
        return names
    }

    private static func toml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
