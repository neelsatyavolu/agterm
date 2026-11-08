import AgTermCore
import Darwin
import Foundation
import SQLite3

/// agterm's project-memory and consult MCP servers, and how each agent gets them. agterm always
/// runs its own copies (Resources/mcp), never agmux's app bundle, so agmux can be uninstalled.
extension AgentIntegration {
    static let memoryServerName = "agmux-memory"

    static var wantMemory: Bool { UserDefaults.standard.object(forKey: memoryKey) as? Bool ?? true }
    static var wantConsult: Bool { UserDefaults.standard.object(forKey: consultKey) as? Bool ?? true }

    static let memoryInstructions = """
        ## agmux project memory
        Shared project memory for every agent on this repo, through the agmux-memory MCP tools.
        1. Call memory_list first to see what earlier agents recorded.
        2. Do the work.
        3. Before your final reply, call session_upsert with a short summary of what you did.
        4. Use memory_add only for lasting decisions, conventions or gotchas.
        """

    /// `userArgs` with agterm's servers added for `agent`, or nil to run them unchanged. OpenCode
    /// and Kilo get theirs through an environment variable instead, set here.
    static func addingMCP(agent: String, userArgs: [String], env: [String: String]) -> [String]? {
        guard AgentMCPLaunch.supported.contains(agent) else { return nil }
        let servers = mcpServers(for: agent, cwd: FileManager.default.currentDirectoryPath, env: env)
        guard !servers.isEmpty else { return nil }
        let instructions = servers.contains { $0.name == memoryServerName } ? memoryInstructions : ""
        switch agent {
        case "claude":
            return AgentLaunch.claude(userArgs: userArgs, servers: servers, instructions: instructions)
        case "codex":
            return AgentLaunch.codex(userArgs: userArgs, servers: servers)
        case "amp":
            return AgentMCPLaunch.amp(userArgs: userArgs, servers: servers)
        case "cursor-agent":
            guard let dir = writeCursorPlugin(servers: servers, instructions: instructions, tabID: env["AGTERM_TAB_ID"]) else { return nil }
            return AgentMCPLaunch.cursor(userArgs: userArgs, pluginDir: dir)
        default:
            // A config you set yourself in the variable is left as it is.
            guard let variable = AgentMCPLaunch.inlineConfigVariable(agent), env[variable] == nil,
                  let config = AgentMCPLaunch.openCodeConfig(servers: servers, instructionsFile: instructions.isEmpty ? nil : instructionsFile())
            else { return nil }
            setenv(variable, config, 1)
            return nil
        }
    }

    /// The servers to add for `agent` started in `cwd`, skipping any the user already configured.
    static func mcpServers(for agent: String, cwd: String, env: [String: String]) -> [MCPServer] {
        guard wantMemory || wantConsult, let bundles = mcpBundles(), let node = findOnPath("node", excluding: nil) else { return [] }
        let existing = configuredServers(for: agent, cwd: cwd)
        let memory = projectMemory(cwd)
        var servers: [MCPServer] = []
        if wantMemory, let memory, !existing.contains(memoryServerName) {
            let session = "agterm-" + (env["AGTERM_TAB_ID"] ?? UUID().uuidString)
            servers.append(MCPServer(name: memoryServerName, command: node, args: [bundles.memory], env: memory.env(sessionID: session)))
        }
        if wantConsult, !existing.contains("consult"), nodeMajorVersion(node) >= 22 {
            // agterm's own consult: agents list and message this Mac's tabs, use the board and (with
            // team sessions on) reach teammates' agents, all through the app's socket.
            var consultEnv = ["PATH": env["PATH"] ?? "", "AGTERM_TEAM_SOCK": TeamSessions.socketPath]
            if let memory { consultEnv["AGMUX_PROJECT_ID"] = memory.project.id }
            servers.append(MCPServer(name: "consult", command: node, args: [bundles.consult], env: consultEnv))
        }
        return servers
    }

    /// The project and store for `cwd`: agmux's for folders in agmux's database (read even when
    /// agmux itself is gone), else the git repo's own in agterm's Application Support folder.
    static func projectMemory(_ cwd: String) -> ProjectMemory? {
        let files = FileManager.default
        return ProjectMemory.resolve(
            cwd: cwd, agmuxProjects: agmuxProjects(), home: NSHomeDirectory(),
            agtermProjectsDir: supportDir.appendingPathComponent("projects").path,
            isRepoRoot: { files.fileExists(atPath: $0 + "/.git") },
            modified: { (try? files.attributesOfItem(atPath: $0))?[.modificationDate] as? Date })
    }

    // MARK: Files

    /// The memory and consult servers agterm ships (Resources/mcp).
    static func mcpBundles() -> (memory: String, consult: String)? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("mcp") else { return nil }
        let memory = dir.appendingPathComponent("agmux-memory-mcp.bundle.mjs").path
        let consult = dir.appendingPathComponent("agmux-consult-mcp.bundle.mjs").path
        guard FileManager.default.fileExists(atPath: memory), FileManager.default.fileExists(atPath: consult) else { return nil }
        return (memory, consult)
    }

    /// agterm's copy of consult: the board, the team session tools and `--answer-team-ask`.
    static func shippedConsultBundle() -> String? {
        mcpBundles()?.consult
    }

    /// The memory instructions as a file, for agents that take instruction files (OpenCode, Kilo).
    private static func instructionsFile() -> String? {
        let url = supportDir.appendingPathComponent("mcp/memory-instructions.md")
        let text = memoryInstructions + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return url.path }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    /// Writes agterm's Cursor plugin for one tab (its servers carry the tab's session) and drops
    /// ones a week old. Returns the plugin folder.
    private static func writeCursorPlugin(servers: [MCPServer], instructions: String, tabID: String?) -> String? {
        let root = supportDir.appendingPathComponent("cursor-plugins", isDirectory: true)
        let files = FileManager.default
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for old in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < weekAgo {
                try? files.removeItem(at: old)
            }
        }
        let name = (tabID ?? UUID().uuidString).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let dir = root.appendingPathComponent(name.isEmpty ? UUID().uuidString : name, isDirectory: true)
        do {
            try? files.removeItem(at: dir)
            for (path, text) in AgentMCPLaunch.cursorPlugin(servers: servers, instructions: instructions) {
                let url = dir.appendingPathComponent(path)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return dir.path
        } catch {
            return nil
        }
    }

    /// Projects from agmux's database, read-only.
    static func agmuxProjects() -> [AgmuxProject] {
        let path = NSHomeDirectory() + "/.agmux/agmux.db"
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, repo_path FROM projects", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var projects: [AgmuxProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let repo = sqlite3_column_text(statement, 1) else { continue }
            projects.append(AgmuxProject(id: String(cString: id), repoPath: String(cString: repo)))
        }
        return projects
    }

    /// MCP server names the user already gave this agent, so agterm doesn't add a second copy.
    private static func configuredServers(for agent: String, cwd: String) -> Set<String> {
        let home = NSHomeDirectory()
        switch agent {
        case "claude":
            var names = Set<String>()
            if let config = json(home + "/.claude.json") {
                names.formUnion((config["mcpServers"] as? [String: Any])?.keys ?? [:].keys)
                if let projects = config["projects"] as? [String: [String: Any]] {
                    for (dir, settings) in projects where cwd == dir || cwd.hasPrefix(dir + "/") {
                        names.formUnion((settings["mcpServers"] as? [String: Any])?.keys ?? [:].keys)
                    }
                }
            }
            for dir in AgentLaunch.folders(upFrom: cwd) where dir != "/" {
                if let mcp = json(dir + "/.mcp.json") {
                    names.formUnion((mcp["mcpServers"] as? [String: Any])?.keys ?? [:].keys)
                }
            }
            return names
        case "codex":
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex"
            let toml = (try? String(contentsOfFile: codexHome + "/config.toml", encoding: .utf8)) ?? ""
            return AgentLaunch.codexServerNames(toml)
        default:
            return AgentMCPLaunch.configFiles(agent: agent, home: home, cwd: cwd).reduce(into: Set<String>()) { names, file in
                if let data = FileManager.default.contents(atPath: file.path) {
                    names.formUnion(AgentMCPLaunch.serverNames(data, key: file.key))
                }
            }
        }
    }

    private static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func nodeMajorVersion(_ node: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        process.waitUntilExit()
        let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(version.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().prefix { $0 != "." }) ?? 0
    }
}
