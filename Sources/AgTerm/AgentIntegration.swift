import AgTermCore
import AgTermSessionKit
import Darwin
import Foundation
import SQLite3

/// Gives agents started in agterm the same MCP servers agmux gives its agents (agmux project
/// memory and consult) and, if you ask for it, starts them without permission prompts. agterm's
/// shells get small `claude`, `codex` and `grok` wrappers first on PATH; each wrapper re-enters
/// this binary (`--agterm-exec`), which works out the extra arguments and execs the real CLI.
enum AgentIntegration {
    /// Agents that get a wrapper: Claude Code, Codex and Grok always (MCP servers, account
    /// switching), others only while "skip permission prompts" is on for them, so agterm shadows
    /// as few commands as it can.
    static var wrappedAgents: [AgentKind] {
        AgentKind.all.filter {
            AccountProvider(rawValue: $0.id) != nil || ($0.bypassFlags != nil && UserDefaults.standard.bool(forKey: bypassKey($0)))
        }
    }
    static let memoryKey = "integrationMemory"
    static let consultKey = "integrationConsult"

    /// UserDefaults key for starting `agent` without permission prompts (off unless you turn it on).
    static func bypassKey(_ agent: AgentKind) -> String { "bypassPermissions." + agent.id }

    /// The agent ⌥⌘T starts.
    static let launchAgentKey = "quickLaunchAgent"
    static var launchAgent: AgentKind {
        UserDefaults.standard.string(forKey: launchAgentKey).flatMap(AgentKind.named) ?? .claude
    }

    /// Agents found on your login shell's PATH, in registry order. Nil until the PATH is known.
    static func installedAgents() -> [AgentKind]? {
        let runner = QuickCommandRunner.shared
        guard runner.isReady else { return nil }
        return AgentKind.all.filter { $0.commands.contains { runner.executable($0) != nil } }
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "agterm-dev", isDirectory: true)
    }
    static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    static var zshDir: URL { supportDir.appendingPathComponent("zsh", isDirectory: true) }

    // MARK: Shell setup (app side)

    /// Writes the wrappers and zsh startup files. Called at launch so the helper path stays current.
    static func installShellIntegration() {
        guard let helper = Bundle.main.executablePath else { return }
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: zshDir, withIntermediateDirectories: true)
            let wanted = Set(wrappedAgents.map(\.command))
            for agent in AgentKind.all {
                let url = binDir.appendingPathComponent(agent.command)
                guard wanted.contains(agent.command) else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                try wrapper(agent: agent.command, helper: helper).write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            for (name, body) in zshFiles() {
                try body.write(to: zshDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("agterm: couldn't install agent wrappers in %@: %@", supportDir.path, error.localizedDescription)
        }
    }

    /// Environment for a new tab's shell.
    static func shellEnvironment(_ env: inout [String: String], tabID: String) {
        let bin = binDir.path
        env["AGTERM_BIN"] = bin
        env["AGTERM_TAB_ID"] = tabID
        env["PATH"] = bin + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // zsh: load the user's startup files through ours, which put the wrappers back first at the end.
        if ProcInfo.loginShell().hasSuffix("/zsh") {
            if let user = env["ZDOTDIR"] { env["AGTERM_USER_ZDOTDIR"] = user }
            env["ZDOTDIR"] = zshDir.path
        }
    }

    private static func wrapper(agent: String, helper: String) -> String {
        """
        #!/bin/sh
        # Added by agterm: starts \(agent) with the options in agterm Settings → Agents.
        # AGTERM_MCP=0 \(agent) … skips the MCP servers. If agterm is gone, this runs the real \(agent) unchanged.
        helper='\(helper.replacingOccurrences(of: "'", with: "'\\''"))'
        if [ -x "$helper" ]; then exec "$helper" --agterm-exec \(agent) "$@"; fi
        here=$(cd "$(dirname "$0")" && pwd)
        PATH=$(printf '%s' "$PATH" | tr ':' '\\n' | grep -vxF "$here" | paste -sd: -)
        exec \(agent) "$@"

        """
    }

    /// Each file runs the user's own copy with ZDOTDIR pointing at the user's folder, then points
    /// ZDOTDIR back here so zsh reads our next file. The last one leaves the user's ZDOTDIR in place.
    private static func zshFiles() -> [(String, String)] {
        let header = "# Added by agterm. Runs your own startup file, then keeps agterm's agent wrappers first on PATH.\n"
        func load(_ file: String) -> String {
            """
            _agterm_dir=$ZDOTDIR
            ZDOTDIR=${AGTERM_USER_ZDOTDIR:-$HOME}
            [[ -r $ZDOTDIR/\(file) ]] && source $ZDOTDIR/\(file)
            AGTERM_USER_ZDOTDIR=$ZDOTDIR
            ZDOTDIR=$_agterm_dir
            """
        }
        let putWrappersFirst = #"[[ -n $AGTERM_BIN ]] && path=("$AGTERM_BIN" ${path:#$AGTERM_BIN})"#
        let finish = """
        \(putWrappersFirst)
        if [[ $AGTERM_USER_ZDOTDIR == $HOME ]]; then unset ZDOTDIR; else ZDOTDIR=$AGTERM_USER_ZDOTDIR; fi
        unset _agterm_dir
        """
        return [
            (".zshenv", header + load(".zshenv") + "\n"),
            (".zprofile", header + load(".zprofile") + "\n"),
            // /etc/zshrc set HISTFILE while ZDOTDIR pointed here; keep the user's history file.
            (".zshrc", header + #"[[ $HISTFILE == $ZDOTDIR/.zsh_history ]] && HISTFILE=${AGTERM_USER_ZDOTDIR:-$HOME}/.zsh_history"# + "\n"
                + load(".zshrc") + "\n" + putWrappersFirst + "\n[[ -o login ]] || {\n" + finish + "\n}\n"),
            (".zlogin", header + load(".zlogin") + "\n" + finish + "\n"),
        ]
    }

    // MARK: Helper mode (runs inside the wrapper, then execs the real agent)

    static func exec(agent: String, args: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        guard let real = findOnPath(agent, excluding: binDir.path) else {
            fputs("agterm: \(agent) not found on PATH\n", stderr)
            exit(127)
        }
        var argv = args
        if let kind = AgentKind.all.first(where: { $0.commands.contains(agent) }), UserDefaults.standard.bool(forKey: bypassKey(kind)) {
            argv = kind.bypassingPermissions(args) ?? args
        }
        let userArgs = argv
        // Grok doesn't say which conversation it's in, so a new one gets an id of agterm's.
        let grok = agent == "grok" ? GrokSessions.launch(args) { UUID().uuidString.lowercased() } : nil
        if let grok { argv = grok.extra + argv }
        if let provider = AccountProvider(rawValue: agent), let home = useAccount(provider, args: args, env: env, sessionID: grok?.sessionID),
           provider == .grok, !args.contains(where: { $0 == "--leader-socket" || $0.hasPrefix("--leader-socket=") }) {
            argv = ["--leader-socket", AccountStore.grokLeaderSocket(home)] + argv
        }
        // Marks Codex sessions as started in agterm (their header's originator), which is how
        // agmux Teams reporting tells them apart from sessions started elsewhere.
        if agent == "codex", env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == nil {
            setenv("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "agterm", 1)
        }
        if env["AGTERM_MCP"] != "0" {
            let servers = mcpServers(for: agent, cwd: FileManager.default.currentDirectoryPath, env: env)
            switch agent {
            case "claude":
                let memory = servers.contains { $0.name == "agmux-memory" } ? memoryInstructions : ""
                argv = AgentLaunch.claude(userArgs: userArgs, servers: servers, instructions: memory) ?? userArgs
            case "codex":
                argv = AgentLaunch.codex(userArgs: userArgs, servers: servers) ?? userArgs
            default:
                break
            }
        }
        let cArgs = ([real] + argv).map { strdup($0) } + [nil]
        execv(real, cArgs)
        fputs("agterm: couldn't start \(real): \(String(cString: strerror(errno)))\n", stderr)
        exit(126)
    }

    /// Points the agent at its login (CLAUDE_CONFIG_DIR / CODEX_HOME / GROK_HOME) and records
    /// which one, with your arguments, so a switch can resume it on another. In order: the login a
    /// switch named (AGTERM_ACCOUNT), a folder you set yourself, then the one for new sessions.
    /// Returns the folder of a login agterm keeps, nil for your own or one you chose.
    private static func useAccount(_ provider: AccountProvider, args: [String], env: [String: String], sessionID: String?) -> URL? {
        unsetenv("AGTERM_ACCOUNT")
        guard let kind = AgentKind.named(provider.rawValue), kind.startsSession(args) else { return nil }
        var folder: URL?
        let settings = AccountStore.loadSettings()
        var id: String
        if let chosen = env["AGTERM_ACCOUNT"] {
            id = chosen
        } else if let home = env[provider.homeVariable] {
            let folder = URL(fileURLWithPath: home).lastPathComponent
            id = settings.accounts.first { $0.provider == provider && AccountStore.home($0.id).path == home }?.id
                ?? (TeamPool.isLocalID(folder) && AccountStore.home(folder).path == home ? folder : AccountStore.external)
        } else {
            id = settings.autoSwitch ? AccountStore.loadRouting().active[provider.rawValue] ?? AccountStore.native : settings.home(provider)
        }
        if id == AccountStore.teamRoute {
            fputs("agterm: your \(provider.title) logins are out of usage, so borrowing one from your team…\n", stderr)
            id = env["AGTERM_TAB_ID"].flatMap { AccountStore.requestTeamAccount(tabID: $0, provider: provider) } ?? AccountStore.native
            if id == AccountStore.native { fputs("agterm: no team login is free; starting on your own.\n", stderr) }
        }
        if id != AccountStore.native, id != AccountStore.external {
            let borrowed = TeamPool.isLocalID(id) && FileManager.default.fileExists(atPath: AccountStore.home(id).appendingPathComponent("auth.json").path)
            if borrowed || settings.accounts.contains(where: { $0.id == id && $0.provider == provider }),
               let home = try? AccountStore.prepareHome(id, provider: provider) {
                // The app keeps a team login lent exactly as long as this process (it becomes the
                // agent). A Codex started from inside that one inherits the folder but not the loan.
                if borrowed, TeamAccounts.liveOwner(home) == nil {
                    try? String(getpid()).write(to: home.appendingPathComponent("owner.pid"), atomically: true, encoding: .utf8)
                }
                setenv(provider.homeVariable, home.path, 1)
                for key in provider.authKeys { unsetenv(key) }
                folder = home
            } else {
                id = AccountStore.native
            }
        }
        if id == AccountStore.native, env["AGTERM_ACCOUNT"] != nil { unsetenv(provider.homeVariable) }
        if let tab = env["AGTERM_TAB_ID"] {
            AccountStore.recordLaunch(TabLaunch(provider: provider, account: id, args: args, startedAt: Date(), sessionID: sessionID), tabID: tab)
        }
        return folder
    }

    static let memoryInstructions = """
        ## agmux project memory
        Shared project memory for every agent on this repo, through the agmux-memory MCP tools.
        1. Call memory_list first to see what earlier agents recorded.
        2. Do the work.
        3. Before your final reply, call session_upsert with a short summary of what you did.
        4. Use memory_add only for lasting decisions, conventions or gotchas.
        """

    /// The servers to add for `agent` started in `cwd`, skipping any the user already configured.
    static func mcpServers(for agent: String, cwd: String, env: [String: String]) -> [MCPServer] {
        let defaults = UserDefaults.standard
        let wantMemory = defaults.object(forKey: memoryKey) as? Bool ?? true
        let wantConsult = defaults.object(forKey: consultKey) as? Bool ?? true
        guard wantMemory || wantConsult, let bundles = mcpBundles(), let node = findOnPath("node", excluding: nil) else { return [] }
        let existing = configuredServers(for: agent, cwd: cwd)
        let home = NSHomeDirectory()
        // With agmux installed, exactly agmux's projects and stores, so memory matches agmux.
        let project = bundles.fromAgmux
            ? AgmuxProject.match(cwd, in: agmuxProjects())
            : AgmuxProject.standalone(cwd) { FileManager.default.fileExists(atPath: $0 + "/.git") }
        var servers: [MCPServer] = []
        if wantMemory, let project, !existing.contains("agmux-memory") {
            let session = "agterm-" + (env["AGTERM_TAB_ID"] ?? UUID().uuidString)
            let memoryEnv = bundles.fromAgmux
                ? project.memoryEnv(home: home, sessionID: session)
                : project.memoryEnv(dataDir: supportDir.appendingPathComponent("projects/" + project.id).path, sessionID: session)
            servers.append(MCPServer(name: "agmux-memory", command: node, args: [bundles.memory], env: memoryEnv))
        }
        if wantConsult, !existing.contains("consult"), nodeMajorVersion(node) >= 22 {
            var consultEnv = ["PATH": env["PATH"] ?? ""]
            if let project { consultEnv["AGMUX_PROJECT_ID"] = project.id }
            servers.append(MCPServer(name: "consult", command: node, args: [bundles.consult], env: consultEnv))
        }
        return servers
    }

    // MARK: Finding things

    /// The memory and consult servers: agmux's own while agmux is installed, else the copies agterm
    /// ships (Resources/mcp).
    static func mcpBundles() -> (memory: String, consult: String, fromAgmux: Bool)? {
        if let agmux = agmuxBundles() { return (agmux.memory, agmux.consult, true) }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("mcp") else { return nil }
        let memory = dir.appendingPathComponent("agmux-memory-mcp.bundle.mjs").path
        let consult = dir.appendingPathComponent("agmux-consult-mcp.bundle.mjs").path
        guard FileManager.default.fileExists(atPath: memory), FileManager.default.fileExists(atPath: consult) else { return nil }
        return (memory, consult, false)
    }

    /// agmux's bundled servers, if agmux is installed. AGTERM_NO_AGMUX=1 acts as if it weren't.
    static func agmuxBundles() -> (memory: String, consult: String)? {
        guard ProcessInfo.processInfo.environment["AGTERM_NO_AGMUX"] != "1" else { return nil }
        for app in ["/Applications/agmux.app", NSHomeDirectory() + "/Applications/agmux.app"] {
            let dist = app + "/Contents/Resources/sidecar/dist/"
            let memory = dist + "agmux-memory-mcp.bundle.mjs", consult = dist + "agmux-consult-mcp.bundle.mjs"
            if FileManager.default.fileExists(atPath: memory), FileManager.default.fileExists(atPath: consult) {
                return (memory, consult)
            }
        }
        return nil
    }

    /// Projects from agmux's database, read-only.
    static func agmuxProjects() -> [AgmuxProject] {
        let path = NSHomeDirectory() + "/.agmux/agmux.db"
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
            var dir = URL(fileURLWithPath: cwd)
            while dir.path != "/" {
                if let mcp = json(dir.appendingPathComponent(".mcp.json").path) {
                    names.formUnion((mcp["mcpServers"] as? [String: Any])?.keys ?? [:].keys)
                }
                dir.deleteLastPathComponent()
            }
            return names
        case "codex":
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex"
            let toml = (try? String(contentsOfFile: codexHome + "/config.toml", encoding: .utf8)) ?? ""
            return AgentLaunch.codexServerNames(toml)
        default:
            return []
        }
    }

    private static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func findOnPath(_ name: String, excluding skip: String?) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":").map(String.init) where dir != skip && !dir.isEmpty {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
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
