import AgTermCore
import AgTermSessionKit
import Darwin
import Foundation

/// Gives agents started in agterm its project memory and consult MCP servers (the ones agmux
/// gives its agents; see AgentIntegrationMCP.swift) and, if you ask for it, starts them without
/// permission prompts. agterm's shells get small wrappers (`claude`, `codex`, `grok`, …) first on
/// PATH; each re-enters this binary (`--agterm-exec`), which works out the extra arguments and
/// execs the real CLI.
enum AgentIntegration {
    /// Agents that get a wrapper: Claude Code, Codex and Grok always (account switching), the
    /// others agterm gives MCP servers while memory or consult is on, and the rest only while
    /// "skip permission prompts" is on for them, so agterm shadows as few commands as it can.
    static var wrappedAgents: [AgentKind] {
        let mcp = wantMemory || wantConsult
        return AgentKind.all.filter {
            AccountProvider(rawValue: $0.id) != nil || (mcp && AgentMCPLaunch.supported.contains($0.id))
                || ($0.bypassFlags != nil && UserDefaults.standard.bool(forKey: bypassKey($0)))
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

    /// Agents found on your login shell's PATH, plus agl when agterm carries it, in registry
    /// order. Nil until the PATH is known.
    static func installedAgents() -> [AgentKind]? {
        let runner = QuickCommandRunner.shared
        guard runner.isReady else { return nil }
        return AgentKind.all.filter { kind in
            kind.commands.contains { runner.executable($0) != nil } || (kind.id == "agl" && bundledAgl != nil)
        }
    }

    /// The agl that ships inside agterm.app (`Contents/MacOS/agl`); nil in debug builds.
    static var bundledAgl: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "agl").flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
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
                    // agl ships with agterm: tabs find it here, first on PATH.
                    if agent.id == "agl", let agl = bundledAgl {
                        try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: agl)
                    }
                    continue
                }
                try wrapper(agent: agent.command, helper: helper).write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            let remote = binDir.appendingPathComponent(remoteCommand)
            try remoteWrapper(helper: helper).write(to: remote, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remote.path)
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

    /// Runs commands on a Mac paired in Settings → Macs (`MacRemote`).
    static let remoteCommand = "agterm-remote"

    private static func remoteWrapper(helper: String) -> String {
        """
        #!/bin/sh
        # Added by agterm: runs a command on a Mac paired in agterm Settings → Macs. `agterm-remote help` says how.
        helper='\(helper.replacingOccurrences(of: "'", with: "'\\''"))'
        if [ -x "$helper" ]; then exec "$helper" \(MacRemote.flag) "$@"; fi
        echo "agterm-remote: agterm isn't at $helper any more; open agterm once to fix this" >&2
        exit 255

        """
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
        // Added to the prompt in precmd, after themes (powerlevel10k, starship) have set it, so it survives them.
        let promptMarks = #"""
        # Marks the prompt (OSC 133) so clicking in the line you're typing moves the cursor there.
        if [[ -o interactive && -z $_agterm_marks ]]; then
          _agterm_marks=1
          autoload -Uz add-zsh-hook
          _agterm_precmd() {
            print -n '\e]133;D\a'
            [[ $PS1 == *'133;A;'* ]] || PS1=$'%{\e]133;A;cl=m\a%}'$PS1$'%{\e]133;B\a%}'
          }
          _agterm_preexec() { print -n '\e]133;C\a' }
          add-zsh-hook precmd _agterm_precmd
          add-zsh-hook preexec _agterm_preexec
        fi
        """#
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
                + load(".zshrc") + "\n" + promptMarks + "\n" + putWrappersFirst + "\n[[ -o login ]] || {\n" + finish + "\n}\n"),
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
        // Recorded so the Chat view can show a resumed conversation before anything is written to it.
        let sessionID = agent == "codex" ? CodexSessions.resumed(args)
            : grok?.sessionID ?? (agent == "grok" ? GrokSessions.continued(args, in: AccountStore.nativeGrokHome.appendingPathComponent("sessions"),
                                                                           cwd: GrokSessions.folder(userArgs: args, processCwd: FileManager.default.currentDirectoryPath)) : nil)
        if let provider = AccountProvider(rawValue: agent), let home = useAccount(provider, args: args, env: env, sessionID: sessionID),
           provider == .grok, !args.contains(where: { $0 == "--leader-socket" || $0.hasPrefix("--leader-socket=") }) {
            argv = ["--leader-socket", AccountStore.grokLeaderSocket(home)] + argv
        }
        // Marks Codex sessions as started in agterm (their header's originator), which is how
        // agterm Teams reporting tells them apart from sessions started elsewhere.
        if agent == "codex", env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == nil {
            setenv("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "agterm", 1)
        }
        if env["AGTERM_MCP"] != "0", let withMCP = addingMCP(agent: agent, userArgs: userArgs, env: env) {
            argv = withMCP
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
            let login = loginIdentity(provider)
            AccountStore.recordLaunch(TabLaunch(provider: provider, account: id, args: args, startedAt: Date(), sessionID: sessionID,
                                                identityHash: login?.hash, loginLabel: login?.label), tabID: tab)
        }
        return folder
    }

    /// The login the agent is about to use, read from the files in the folder it was just pointed
    /// at (or your own), for splitting Teams usage by login. Nil when they don't name one.
    private static func loginIdentity(_ provider: AccountProvider) -> (hash: String, label: String?)? {
        let dir = getenv(provider.homeVariable).map { URL(fileURLWithPath: String(cString: $0)) }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch provider {
        case .claude:
            // Claude Code keeps its login in <CLAUDE_CONFIG_DIR>/.claude.json, else ~/.claude.json.
            let file = (dir ?? home).appendingPathComponent(".claude.json")
            return (try? Data(contentsOf: file)).flatMap(LoginIdentity.claude(configJSON:))
        case .codex:
            let file = (dir ?? home.appendingPathComponent(".codex")).appendingPathComponent("auth.json")
            return (try? Data(contentsOf: file)).flatMap(LoginIdentity.codexHash(authJSON:)).map { ($0, nil) }
        default:
            return nil
        }
    }

    static func findOnPath(_ name: String, excluding skip: String?) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":").map(String.init) where dir != skip && !dir.isEmpty {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
