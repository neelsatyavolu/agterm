import Foundation

// MARK: Saved workspace

/// Everything needed to reopen the window as it was at quit.
public struct SavedWorkspace: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = SavedWorkspace.currentVersion
    public var savedAt: Date
    public var selected: Int
    public var tabs: [SavedTab]

    public init(selected: Int, tabs: [SavedTab], savedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.selected = selected
        self.tabs = tabs
        self.savedAt = savedAt
    }

    public struct UnsupportedVersion: Error {}

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// Rejects files from other versions and clamps the selection to the saved tabs.
    public static func decode(_ data: Data) throws -> SavedWorkspace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var workspace = try decoder.decode(SavedWorkspace.self, from: data)
        guard workspace.version == currentVersion else { throw UnsupportedVersion() }
        workspace.selected = min(max(workspace.selected, 0), max(workspace.tabs.count - 1, 0))
        return workspace
    }
}

public struct SavedTab: Codable, Equatable, Sendable {
    public var cwd: String
    /// The tab's history as text with ANSI color codes, oldest line first.
    public var scrollback: String
    /// A command to type once the shell is up, e.g. `command claude --resume <id>`.
    public var resume: String?
    /// The sessions helper's id for the tab's shell, if it ran there. Saves from before the
    /// helper have none (decoded with `decodeIfPresent`, which optional properties get for free).
    public var sessionID: String?
    /// The tab's id, which its shell (and any agent started there) was given as AGTERM_TAB_ID;
    /// a reattached tab keeps it.
    public var tabID: String?

    public init(cwd: String, scrollback: String, resume: String?, sessionID: String? = nil, tabID: String? = nil) {
        self.cwd = cwd
        self.scrollback = scrollback
        self.resume = resume
        self.sessionID = sessionID
        self.tabID = tabID
    }
}

/// How each tab comes back at launch.
public enum LaunchTab: Equatable {
    /// The helper kept the shell: show it again.
    case reattach(SessionInfo, saved: SavedTab?)
    /// The shell is gone: a new one, with the saved history and agent.
    case restore(SavedTab)

    /// The saved tabs in their order, each reattached if the helper still lists its session, then
    /// the helper's other sessions (a crash before the last save), oldest first.
    ///
    /// Sessions another client is showing (another agterm) are left to it, and so is a saved tab
    /// whose session that is: neither reattached nor reopened. `live` is nil when the helper can't
    /// be asked: a tab that was in it reopens from its history without its resume command, since
    /// its agent may well still be running there.
    public static func plan(saved: [SavedTab], live: [SessionInfo]?) -> [LaunchTab] {
        guard let live else {
            return saved.map { tab in
                guard tab.sessionID != nil else { return .restore(tab) }
                var history = tab
                history.resume = nil
                return .restore(history)
            }
        }
        let elsewhere = Set(live.filter(\.attached).map(\.id))
        var unclaimed = live.filter { !$0.attached }
        let tabs: [LaunchTab] = saved.compactMap { tab in
            if let id = tab.sessionID, elsewhere.contains(id) { return nil }
            guard let index = unclaimed.firstIndex(where: { $0.id == tab.sessionID }) else { return .restore(tab) }
            return .reattach(unclaimed.remove(at: index), saved: tab)
        }
        return tabs + unclaimed.map { .reattach($0, saved: nil) }
    }
}

// MARK: Resuming agents

/// Rebuilds the command that brings an agent back in a restored tab. Only agents that can
/// resume a conversation are rerun; anything else (a dev server, `rm`, an editor) is not.
public enum AgentResume {
    /// Claude Code flags whose next argument is their value.
    private static let claudeValueFlags: Set<String> = [
        "--model", "--fallback-model", "--permission-mode", "--add-dir", "--allowedTools", "--allowed-tools",
        "--disallowedTools", "--disallowed-tools", "--mcp-config", "--settings", "--setting-sources", "--agent",
        "--agents", "--append-system-prompt", "--system-prompt", "--effort", "--plugin-dir", "--betas",
        "--output-format", "--input-format",
    ]
    /// Flags that pick or start a session; the restored tab chooses its own.
    private static let sessionFlagsWithValue: Set<String> = ["--resume", "-r", "--session-id"]
    private static let sessionFlags: Set<String> = ["--continue", "-c", "--fork-session"]

    /// `argv` is the foreground process's full argument list; `claudeSessionID` comes from
    /// Claude Code's per-process record. Returns nil for programs that shouldn't be rerun.
    /// `prompt`, if given, is sent as the first message of the resumed session.
    public static func commandLine(argv: [String], claudeSessionID: String?, prompt: String? = nil) -> String? {
        guard let args = claudeArguments(argv) else { return nil }
        if args.contains("-p") || args.contains("--print") { return nil }

        var kept: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if sessionFlagsWithValue.contains(arg) {
                i += 2
                continue
            }
            if sessionFlags.contains(arg) || arg.hasPrefix("--resume=") || arg.hasPrefix("--session-id=") {
                i += 1
                continue
            }
            if claudeValueFlags.contains(arg), i + 1 < args.count {
                kept += [arg, args[i + 1]]
                i += 2
                continue
            }
            // A bare argument is the opening prompt; resuming must not send it again.
            if arg.hasPrefix("-") { kept.append(arg) }
            i += 1
        }
        let session = claudeSessionID.map { ["--resume", $0] } ?? ["--continue"]
        // The prompt goes straight after the session, before any option that takes several values.
        return (["command", "claude"] + (session + (prompt.map { [$0] } ?? []) + kept).map(ShellEscape.path)).joined(separator: " ")
    }

    /// Codex options that take a value; everything else starting with "-" is a switch.
    private static let codexValueFlags: Set<String> = [
        "-m", "--model", "-c", "--config", "-s", "--sandbox", "-a", "--ask-for-approval", "-p", "--profile",
        "-C", "--cd", "--add-dir", "--local-provider", "--enable", "--disable",
    ]

    /// Codex subcommands that don't run an interactive session.
    private static let codexOtherCommands: Set<String> = [
        "exec", "e", "review", "apply", "a", "login", "logout", "mcp", "mcp-server", "app-server", "completion",
        "sandbox", "debug", "cloud", "features", "help", "update", "doctor",
    ]

    /// `codex resume <id>` with the options you started Codex with, minus the opening prompt
    /// and any session choice. Nil for runs that aren't an interactive session (exec, review…).
    /// `prompt`, if given, is sent as the first message of the resumed session.
    public static func codexCommandLine(userArgs: [String], sessionID: String, prompt: String? = nil) -> String? {
        var args = userArgs
        if let first = args.first, !first.hasPrefix("-") {
            if codexOtherCommands.contains(first) { return nil }
            if ["resume", "fork"].contains(first) { args.removeFirst() }
        }
        var kept: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if codexValueFlags.contains(arg), i + 1 < args.count {
                kept += [arg, args[i + 1]]
                i += 2
                continue
            }
            // Bare words are the opening prompt (or the old session id); resuming must not resend them.
            if arg.hasPrefix("-"), arg != "--last", arg != "--all" { kept.append(arg) }
            i += 1
        }
        return (["command", "codex", "resume", sessionID] + ((prompt.map { [$0] } ?? []) + kept).map(ShellEscape.path))
            .joined(separator: " ")
    }

    /// Grok options that take a value; everything else starting with "-" is a switch.
    private static let grokValueFlags: Set<String> = [
        "--add-dir", "--agent", "--agents", "--allow", "--allowedTools", "--allowed-tools", "--cwd", "--debug-file",
        "--deny", "--disallowedTools", "--disallowed-tools", "--json-schema", "-m", "--model", "--max-turns",
        "--output-format", "--permission-mode", "--reasoning-effort", "--effort", "--rules", "--sandbox",
        "--system-prompt-override", "--tools",
    ]

    /// `grok --resume <id>` with the options you started Grok with, minus the opening prompt, any
    /// session choice and the leader socket (each login gets its own). Nil for one-shot runs,
    /// subcommands and worktree runs (their conversation lives under the worktree's folder).
    /// `prompt`, if given, is sent as the first message of the resumed session.
    public static func grokCommandLine(userArgs: [String], sessionID: String, prompt: String? = nil) -> String? {
        func name(_ arg: String) -> String { arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg }
        let oneShot: Set<String> = ["-p", "--single", "--prompt-file", "--prompt-json", "-w", "--worktree", "--worktree-ref"]
        guard AgentKind.grok.startsSession(userArgs), !userArgs.contains(where: { oneShot.contains(name($0)) }) else { return nil }
        var kept: [String] = []
        var i = 0
        while i < userArgs.count {
            let arg = userArgs[i]
            if ["-s", "--session-id", "--leader-socket"].contains(arg) {
                i += 2
                continue
            }
            if ["-r", "--resume"].contains(arg) {
                // Its value is optional.
                i += i + 1 < userArgs.count && !userArgs[i + 1].hasPrefix("-") ? 2 : 1
                continue
            }
            if ["-c", "--continue", "--fork-session", "--restore-code", "--resume", "--session-id", "--leader-socket"].contains(name(arg)) {
                i += 1
                continue
            }
            if grokValueFlags.contains(arg), i + 1 < userArgs.count {
                kept += [arg, userArgs[i + 1]]
                i += 2
                continue
            }
            // Bare words are the opening prompt; resuming must not resend it.
            if arg.hasPrefix("-") { kept.append(arg) }
            i += 1
        }
        return (["command", "grok", "--resume", sessionID] + ((prompt.map { [$0] } ?? []) + kept).map(ShellEscape.path))
            .joined(separator: " ")
    }

    /// Agents whose conversation id agterm can't read: each one's own way to continue its
    /// latest conversation (most are per folder, and the tab reopens in the same folder).
    /// Flags come from each CLI's --help. Claude Code and Codex resume the exact conversation
    /// instead (`commandLine`, `codexCommandLine`).
    static let continueLatest: [String: [String]] = [
        "grok": ["--continue"], "gemini": ["--resume", "latest"], "agy": ["--continue"],
        "cursor-agent": ["--continue"], "opencode": ["--continue"], "kimi": ["--continue"],
        "aider": ["--restore-chat-history"], "droid": ["--resume"], "kilo": ["--continue"],
        "auggie": ["--continue"], "pi": ["--continue"], "copilot": ["--continue"], "goose": ["session", "--resume"],
    ]

    /// Brings back another agent's latest conversation, or nil for agents without a way to, and
    /// for one-shot runs (`-p`), which have nothing to come back to.
    public static func continueCommandLine(agent: String, argv: [String]) -> String? {
        guard let kind = AgentKind.named(agent), let flags = continueLatest[kind.id],
              !argv.dropFirst().contains(where: { ["-p", "--print", "--prompt"].contains($0) }) else { return nil }
        return (["command", kind.command] + flags.map(ShellEscape.path)).joined(separator: " ")
    }

    /// A Codex rollout's session id, from its first line (`session_meta.payload.id`).
    public static func codexSessionID(rolloutHeader: String) -> String? {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(rolloutHeader.utf8))) as? [String: Any],
              let id = (record["payload"] as? [String: Any])?["id"] as? String,
              id.range(of: #"^[0-9A-Za-z-]{8,64}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// The arguments after the program itself, if the process is Claude Code (native or via node).
    private static func claudeArguments(_ argv: [String]) -> [String]? {
        guard let first = argv.first else { return nil }
        if (first as NSString).lastPathComponent == "claude" { return Array(argv.dropFirst()) }
        if let script = argv.firstIndex(where: { $0.hasSuffix("claude-code/cli.js") }) {
            return Array(argv[(script + 1)...])
        }
        return nil
    }
}

// MARK: ANSI encoding of saved history

public enum CellColor: Equatable, Sendable {
    case `default`
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// Same bit layout as SwiftTerm's CharacterStyle.
public struct CellStyle: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = CellStyle(rawValue: 1)
    public static let underline = CellStyle(rawValue: 2)
    public static let blink = CellStyle(rawValue: 4)
    public static let inverse = CellStyle(rawValue: 8)
    public static let invisible = CellStyle(rawValue: 16)
    public static let dim = CellStyle(rawValue: 32)
    public static let italic = CellStyle(rawValue: 64)
    public static let crossedOut = CellStyle(rawValue: 128)
}

public enum SGR {
    /// The escape sequence that sets exactly these attributes (it starts with a reset).
    public static func sequence(fg: CellColor, bg: CellColor, style: CellStyle) -> String {
        var codes = ["0"]
        let styles: [(CellStyle, String)] = [(.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"),
                                              (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9")]
        codes += styles.filter { style.contains($0.0) }.map(\.1)
        codes += color(fg, base: 30, bright: 90, extended: 38)
        codes += color(bg, base: 40, bright: 100, extended: 48)
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    private static func color(_ c: CellColor, base: Int, bright: Int, extended: Int) -> [String] {
        switch c {
        case .default: return []
        case .ansi(let n) where n < 8: return [String(base + Int(n))]
        case .ansi(let n) where n < 16: return [String(bright + Int(n) - 8)]
        case .ansi(let n): return [String(extended), "5", String(n)]
        case let .rgb(r, g, b): return [String(extended), "2", String(r), String(g), String(b)]
        }
    }
}

// MARK: Tab order

public enum TabOrder {
    /// `items` with the element at `from` moved to `to`; out-of-range indices change nothing.
    public static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to) else { return items }
        var copy = items
        copy.insert(copy.remove(at: from), at: to)
        return copy
    }

    /// Where the selected tab ends up after moving the tab at `from` to `to`.
    public static func selection(afterMoving from: Int, to: Int, selected: Int) -> Int {
        if selected == from { return to }
        if from < selected, to >= selected { return selected - 1 }
        if from > selected, to <= selected { return selected + 1 }
        return selected
    }
}
