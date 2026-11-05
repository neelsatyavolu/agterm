import Foundation

/// agterm's additions to the agmux relay protocol, shared by the Mac app and agterm Remote on iPhone.
///
/// The relay forwards only its own message types, so everything here rides inside them as extra
/// fields, which the agmux phone app ignores:
///
/// - Thread rows carry an `agterm` object (`TabInfo`): status, folder, branch and any prompt on screen.
/// - `thread.subscribe` with `screen: true` leases a tab's live screen for `screenLease` seconds;
///   the phone renews it every `screenRenew` with `renew: true` (anything else gets a full frame). The Mac answers with `timeline.snapshot` on the thread
///   `screen:<tab id>` (which agmux never opens), `entries: []` and a `screen` (`ScreenSnapshot`).
/// - `thread.subscribe` with `lease: true` reads the tab's conversation on the same lease terms
///   (agmux's plain subscriptions never lapse, since the relay doesn't forward unsubscribes).
/// - `message.send` with `raw: true` types `text` as is (no line clear, no Enter), then `keys`
///   (`TerminalKey` names) in order.
public enum AgTermWire {
    /// agmux's hub; the Mac and the phone must dial the same one.
    public static let defaultRelay = "wss://agmux-remote-relay.xanom.workers.dev/ws"
    /// `thread.create` provider for a tab with no agent.
    public static let shellProvider = "shell"
    public static let screenPrefix = "screen:"
    public static let screenLease: TimeInterval = 45
    public static let screenRenew: TimeInterval = 20
    /// Scrollback rows sent above the visible screen.
    public static let screenHistory = 150
    /// The relay drops frames over 1 MiB; leave room for the envelope.
    public static let frameBudget = 900_000

    public static func screenThread(_ tabID: String) -> String { screenPrefix + tabID }

    public static func tabID(screenThread: String) -> String? {
        screenThread.hasPrefix(screenPrefix) ? String(screenThread.dropFirst(screenPrefix.count)) : nil
    }

    /// The thread's provider as agmux names it, for the agent in a tab (nil: a plain terminal).
    public static func provider(agent: String?) -> String {
        switch agent {
        case "claude": "ClaudeCode"
        case "codex": "Codex"
        case "grok": "Grok"
        case let name?: name.prefix(1).uppercased() + name.dropFirst()
        case nil: "Terminal"
        }
    }
}

// MARK: Pairing

/// What a pairing QR code carries. agterm's own form is `agterm-remote://pair#pair=…&desktopId=…`
/// (plus `&relay=` when the Mac uses a non-default relay); agmux's https links are read too.
public struct PairLink: Equatable, Sendable {
    public static let scheme = "agterm-remote"
    private static let agmuxHosts: Set<String> = ["remote.agmux.dev", "agmux.dev"]

    public let code: String
    public let desktopId: String
    public let relay: String?

    public init(code: String, desktopId: String, relay: String?) {
        self.code = code.uppercased()
        self.desktopId = desktopId
        self.relay = relay
    }

    public init?(url: URL) {
        switch url.scheme?.lowercased() {
        case Self.scheme?: break
        case "https"?: guard let host = url.host?.lowercased(), Self.agmuxHosts.contains(host) else { return nil }
        default: return nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if let fragment = components?.percentEncodedFragment {
            var parsed = URLComponents()
            parsed.percentEncodedQuery = fragment
            items += parsed.queryItems ?? []
        }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let code = value("pair"), let desktop = value("desktopId") else { return nil }
        let relay = value("relay")
        if let relay, !(relay.hasPrefix("wss://") || relay.hasPrefix("ws://")) { return nil }
        self.init(code: code, desktopId: desktop, relay: relay)
    }

    public var url: URL {
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "pair", value: code), URLQueryItem(name: "desktopId", value: desktopId)]
            + (relay.map { [URLQueryItem(name: "relay", value: $0)] } ?? [])
        // swiftlint:disable:next force_unwrapping
        return URL(string: "\(Self.scheme)://pair#" + (fragment.percentEncodedQuery ?? ""))!
    }
}

// MARK: Keys

/// Keys the phone can press in a tab. The Mac turns them into bytes, since arrows depend on the
/// terminal's cursor mode.
public enum TerminalKey: String, CaseIterable, Codable, Sendable {
    case esc, tab, shiftTab, enter, up, down, left, right, ctrlC, backspace

    public func bytes(applicationCursor: Bool) -> String {
        let arrow = applicationCursor ? "\u{1b}O" : "\u{1b}["
        switch self {
        case .esc: return "\u{1b}"
        case .tab: return "\t"
        case .shiftTab: return "\u{1b}[Z"
        case .enter: return "\r"
        case .up: return arrow + "A"
        case .down: return arrow + "B"
        case .right: return arrow + "C"
        case .left: return arrow + "D"
        case .ctrlC: return "\u{3}"
        case .backspace: return "\u{7f}"
        }
    }
}

// MARK: Tabs

extension TabStatus {
    public var wireName: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .waiting: "needsYou"
        case .exited: "exited"
        }
    }

    public init?(wireName: String) {
        guard let status = [TabStatus.idle, .working, .done, .waiting, .exited].first(where: { $0.wireName == wireName })
        else { return nil }
        self = status
    }
}

/// A numbered answer on an agent's prompt; pressing `key` picks it.
public struct PromptChoice: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let selected: Bool

    public init(key: String, label: String, selected: Bool) {
        self.key = key
        self.label = label
        self.selected = selected
    }
}

public struct PromptInfo: Codable, Equatable, Sendable {
    public let question: String?
    public let choices: [PromptChoice]

    public init(question: String?, choices: [PromptChoice]) {
        self.question = question
        self.choices = choices
    }
}

/// What agterm knows about a tab beyond agmux's thread fields.
public struct TabInfo: Codable, Equatable, Sendable {
    /// `TabStatus.wireName`.
    public var status: String
    public var agent: String?
    public var folder: String
    public var branch: String?
    /// The question on screen while the tab needs you.
    public var prompt: PromptInfo?

    public init(status: TabStatus, agent: String?, folder: String, branch: String?, prompt: PromptInfo?) {
        self.status = status.wireName
        self.agent = agent
        self.folder = folder
        self.branch = branch
        self.prompt = prompt
    }

    public var tabStatus: TabStatus { TabStatus(wireName: status) ?? .idle }
}

/// One tab as a relay thread row: agmux's fields (so the agmux phone app still works) plus `agterm`.
public struct RemoteTabRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var provider: String
    public var interactionMode: String?
    public var surface: String?
    public var projectName: String?
    public var processing: Bool
    public var unread: Bool?
    public var needsApproval: Bool
    public var lastActive: String
    public var status: String?
    public var model: String?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var agterm: TabInfo?

    public init(id: String, title: String, provider: String, projectName: String?, processing: Bool,
                unread: Bool, needsApproval: Bool, lastActive: String, status: String, model: String?,
                linesAdded: Int?, linesRemoved: Int?, agterm: TabInfo) {
        self.id = id
        self.title = title
        self.provider = provider
        interactionMode = "pty"
        surface = "terminal"
        self.projectName = projectName
        self.processing = processing
        self.unread = unread
        self.needsApproval = needsApproval
        self.lastActive = lastActive
        self.status = status
        self.model = model
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.agterm = agterm
    }
}

// MARK: New tabs

/// What the phone can open a new tab with, sent as `agterm` on `threads.snapshot`. The phone asks
/// with `thread.create` (`provider`: an agent id or `AgTermWire.shellProvider`, `projectId`: a
/// folder); the Mac answers `thread.created` with the new tab's row.
public struct NewTabOptions: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var agents: [Agent]
    public var folders: [String]
    /// The Mac's home folder, so the phone can show paths as `~/…`.
    public var home: String

    public init(agents: [Agent], folders: [String], home: String) {
        self.agents = agents
        self.folders = folders
        self.home = home
    }

    /// Open tabs' folders first, then agmux projects, then home: existing folders only, each once.
    public static func folders(tabs: [String], projects: [String], home: String, limit: Int = 30,
                               exists: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return (tabs + projects + [home]).filter { seen.insert($0).inserted && exists($0) }.prefix(limit).map { $0 }
    }

    /// The command a new tab types for `provider`: `.some(nil)` for a plain shell, nil for an
    /// unknown provider. Only agents agterm knows can be started, never an arbitrary command.
    public static func command(provider: String) -> String?? {
        if provider == AgTermWire.shellProvider { return .some(nil) }
        return AgentKind.named(provider).map { .some($0.command) } ?? nil
    }
}
