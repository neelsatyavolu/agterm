import Foundation

/// How agterm hands its MCP servers (and the memory instructions) to agents other than Claude
/// Code and Codex (see AgentLaunch), each through a per-launch mechanism that leaves the user's
/// own config files alone. Checked against each CLI's --help, docs or code:
/// - OpenCode and Kilo merge an inline config from OPENCODE_CONFIG_CONTENT / KILO_CONFIG_CONTENT
///   over theirs (MCP servers by name; `instructions` lists are joined).
/// - Cursor Agent loads a local plugin from `--plugin-dir`: its mcp.json and an always-on rule.
/// - Amp takes `--mcp-config <json>`, which doesn't need approval.
/// Not wired, as none has a per-launch way to add a server: Grok (its GROK_CONFIG overlay can't
/// set MCP servers), Gemini CLI (its settings overrides must be owned by root), Factory Droid,
/// Kimi Code, and Cline (only by replacing its whole MCP settings file).
public enum AgentMCPLaunch {
    /// Agents agterm adds its MCP servers to.
    public static let supported: Set<String> = ["claude", "codex", "opencode", "kilo", "cursor-agent", "amp"]

    /// The variable OpenCode or Kilo reads an inline config from, nil for other agents.
    public static func inlineConfigVariable(_ command: String) -> String? {
        switch command {
        case "opencode": "OPENCODE_CONFIG_CONTENT"
        case "kilo", "kilocode": "KILO_CONFIG_CONTENT"
        default: nil
        }
    }

    /// OpenCode / Kilo inline config: local servers, plus the memory instructions file if given.
    public static func openCodeConfig(servers: [MCPServer], instructionsFile: String?) -> String? {
        guard !servers.isEmpty else { return nil }
        var mcp: [String: Any] = [:]
        for server in servers {
            mcp[server.name] = ["type": "local", "command": [server.command] + server.args,
                                "environment": server.env, "enabled": true]
        }
        var config: [String: Any] = ["mcp": mcp]
        if let instructionsFile { config["instructions"] = [instructionsFile] }
        return json(config)
    }

    /// Arguments for `amp`: one `--mcp-config` with a name → server map. Nil to run it unchanged.
    public static func amp(userArgs: [String], servers: [MCPServer]) -> [String]? {
        guard !servers.isEmpty, AgentKind.named("amp")?.startsSession(userArgs) ?? true,
              !userArgs.contains(where: { $0 == "--mcp-config" || $0.hasPrefix("--mcp-config=") }) else { return nil }
        guard let config = json(standardServers(servers)) else { return nil }
        return ["--mcp-config", config] + userArgs
    }

    /// Arguments for `cursor-agent`, loading agterm's plugin from `pluginDir`. Nil to run it unchanged.
    public static func cursor(userArgs: [String], pluginDir: String) -> [String]? {
        guard AgentKind.named("cursor-agent")?.startsSession(userArgs) ?? true else { return nil }
        return ["--plugin-dir", pluginDir] + userArgs
    }

    /// The files of agterm's Cursor plugin, by path inside the plugin folder. Cursor lists its
    /// servers as plugin-agterm-<name>.
    public static func cursorPlugin(servers: [MCPServer], instructions: String) -> [String: String] {
        var files: [String: String] = [:]
        files[".cursor-plugin/plugin.json"] = json(["name": "agterm", "description": "Project memory and consult from agterm"])
        files["mcp.json"] = json(["mcpServers": standardServers(servers)])
        if !instructions.isEmpty {
            files["rules/agterm-memory.mdc"] = "---\ndescription: agterm project memory\nalwaysApply: true\n---\n\n" + instructions + "\n"
        }
        return files
    }

    /// The user's own config files that can name MCP servers for `agent`, with the key holding
    /// them, so agterm skips a server already configured instead of replacing it.
    public static func configFiles(agent: String, home: String, cwd: String) -> [(path: String, key: String)] {
        let folders = AgentLaunch.folders(upFrom: cwd).filter { $0 != "/" }
        func files(_ global: [String], _ local: [String], key: String) -> [(path: String, key: String)] {
            global.map { (home + "/" + $0, key) } + folders.flatMap { dir in local.map { (dir + "/" + $0, key) } }
        }
        switch agent {
        case "opencode":
            return files([".config/opencode/opencode.json", ".config/opencode/opencode.jsonc", ".config/opencode/config.json"],
                         ["opencode.json", "opencode.jsonc", ".opencode/opencode.json", ".opencode/opencode.jsonc"], key: "mcp")
        case "kilo", "kilocode":
            return files([".config/kilo/kilo.json", ".config/kilo/kilo.jsonc", ".config/kilo/opencode.json", ".config/kilo/opencode.jsonc"],
                         ["kilo.json", "kilo.jsonc", "opencode.json", "opencode.jsonc", ".kilo/kilo.json", ".kilo/kilo.jsonc"], key: "mcp")
        case "amp":
            return files([".config/amp/settings.json", ".config/amp/settings.jsonc"],
                         [".amp/settings.json", ".amp/settings.jsonc"], key: "amp.mcpServers")
        case "cursor-agent":
            return files([".cursor/mcp.json"], [".cursor/mcp.json"], key: "mcpServers")
        default:
            return []
        }
    }

    /// Server names under `key` in a JSON or JSONC file; empty if it doesn't parse.
    public static func serverNames(_ data: Data, key: String) -> Set<String> {
        let text = stripJSONC(String(decoding: data, as: UTF8.self))
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let servers = object[key] as? [String: Any] else { return [] }
        return Set(servers.keys)
    }

    // MARK: Helpers

    /// The common `command` / `args` / `env` form (Cursor, Amp).
    private static func standardServers(_ servers: [MCPServer]) -> [String: Any] {
        var map: [String: Any] = [:]
        for server in servers { map[server.name] = ["command": server.command, "args": server.args, "env": server.env] }
        return map
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSONC to JSON: drops // and /* */ comments and commas before } or ], outside strings.
    static func stripJSONC(_ text: String) -> String {
        dropTrailingCommas(Array(dropComments(Array(text))))
    }

    private static func dropComments(_ chars: [Character]) -> String {
        var out = "", i = 0, inString = false
        while i < chars.count {
            let c = chars[i], next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inString {
                out.append(c)
                if c == "\\", let next { out.append(next); i += 1 } else if c == "\"" { inString = false }
            } else if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            } else if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i += 1
        }
        return out
    }

    private static func dropTrailingCommas(_ chars: [Character]) -> String {
        var out = "", inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == ",", let after = chars[(i + 1)...].first(where: { !$0.isWhitespace }), after == "}" || after == "]" {
                continue
            }
            out.append(c)
        }
        return out
    }
}
