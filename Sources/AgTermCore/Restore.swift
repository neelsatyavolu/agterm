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

    public init(cwd: String, scrollback: String, resume: String?) {
        self.cwd = cwd
        self.scrollback = scrollback
        self.resume = resume
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
    public static func commandLine(argv: [String], claudeSessionID: String?) -> String? {
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
        return (["command", "claude"] + (session + kept).map(ShellEscape.path)).joined(separator: " ")
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
