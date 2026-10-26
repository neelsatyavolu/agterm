import AgTermCore
import AgTermSessionKit
import Foundation

/// A login added in Settings → Accounts. Your normal login is the implicit `AccountStore.native`.
struct StoredAccount: Codable, Identifiable, Equatable {
    let id: String
    let provider: AccountProvider
    var label: String
    var email: String?
    var plan: String?
    var enabled: Bool
}

/// Which login new sessions use. Written by the app, read by the agent wrapper. A switch names
/// its login on the resume command itself (AGTERM_ACCOUNT), so it doesn't go through here.
struct AccountRouting: Codable, Equatable {
    /// Provider → account for new sessions; absent means your own login.
    var active: [String: String] = [:]
}

/// What the wrapper recorded when it started an agent in a tab: the login and your arguments.
struct TabLaunch: Codable {
    let provider: AccountProvider
    let account: String
    let args: [String]
    let startedAt: Date
    /// Grok: the conversation it runs, when known (it doesn't say which one itself).
    var sessionID: String? = nil
}

/// Logins live in Application Support/<bundle id>/accounts/<id>/, one folder each, pointed at
/// with CLAUDE_CONFIG_DIR, CODEX_HOME or GROK_HOME. Conversations, settings and tools are
/// symlinked to your own ~/.claude, ~/.codex or ~/.grok, so any login can resume any conversation.
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    static let native = "native"
    /// A login folder you chose yourself (CLAUDE_CONFIG_DIR / CODEX_HOME): agterm leaves it alone.
    static let external = "external"
    /// Routing for new sessions: borrow a team login (every login of yours is out).
    static let teamRoute = "team"

    struct Settings: Codable {
        var autoSwitch = true
        var continueAfterSwitch = true
        var accounts: [StoredAccount] = []
    }

    @Published private(set) var settings: Settings

    private init() { settings = Self.loadSettings() }

    static var dir: URL { AgentIntegration.supportDir.appendingPathComponent("accounts", isDirectory: true) }
    private static var settingsURL: URL { dir.appendingPathComponent("accounts.json") }
    private static var routingURL: URL { dir.appendingPathComponent("routing.json") }
    private static var launchesDir: URL { dir.appendingPathComponent("launches", isDirectory: true) }
    static var requestsDir: URL { dir.appendingPathComponent("requests", isDirectory: true) }

    static func home(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }

    func accounts(_ provider: AccountProvider) -> [StoredAccount] { settings.accounts.filter { $0.provider == provider } }

    func account(_ id: String) -> StoredAccount? { settings.accounts.first { $0.id == id } }

    func label(_ id: String, provider: AccountProvider) -> String {
        id == Self.native ? "your \(provider.title) login" : account(id)?.label ?? "another account"
    }

    func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next.accounts != settings.accounts || next.autoSwitch != settings.autoSwitch
            || next.continueAfterSwitch != settings.continueAfterSwitch else { return }
        settings = next
        Self.write(next, to: Self.settingsURL)
    }

    /// Adds a login, or updates it in place.
    func add(_ account: StoredAccount) {
        update { settings in
            if let index = settings.accounts.firstIndex(where: { $0.id == account.id }) {
                settings.accounts[index] = account
            } else {
                settings.accounts.append(account)
            }
        }
    }

    /// Forgets a login and deletes its folder. Claude Code keeps the token in the Keychain, so it
    /// signs out first to remove that too.
    func remove(_ id: String) {
        guard let account = account(id) else { return }
        update { $0.accounts.removeAll { $0.id == id } }
        var routing = Self.loadRouting()
        routing.active = routing.active.filter { $0.value != id }
        Self.saveRouting(routing)
        Self.deleteHome(id, provider: account.provider)
    }

    /// Deletes a login's folder, signing Claude Code out first so its Keychain entry goes too.
    static func deleteHome(_ id: String, provider: AccountProvider) {
        let home = home(id)
        DispatchQueue.global(qos: .utility).async {
            if provider == .claude, let cli = QuickCommandRunner.shared.executable("claude") {
                let logout = Process()
                logout.executableURL = URL(fileURLWithPath: cli)
                logout.arguments = ["auth", "logout"]
                logout.environment = UsageProbe.environment(.claude, home: home)
                _ = QuickCommandRunner.execute(logout, timeout: 20)
            }
            try? FileManager.default.removeItem(at: home)
        }
    }

    // MARK: Files shared with the wrapper (it runs in its own process)

    static func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    static func loadRouting() -> AccountRouting {
        guard let data = try? Data(contentsOf: routingURL), let routing = try? JSONDecoder().decode(AccountRouting.self, from: data) else { return AccountRouting() }
        return routing
    }

    static func saveRouting(_ routing: AccountRouting) { write(routing, to: routingURL) }

    static func recordLaunch(_ launch: TabLaunch, tabID: String) {
        write(launch, to: launchesDir.appendingPathComponent("\(tabID)-\(launch.provider.rawValue).json"))
    }

    static func launch(tabID: String, provider: AccountProvider) -> TabLaunch? {
        let url = launchesDir.appendingPathComponent("\(tabID)-\(provider.rawValue).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TabLaunch.self, from: data)
    }

    /// Wrapper side: asks the app for a team login for this tab and waits for the answer.
    /// The app holds the loan; the wrapper only learns which folder to use.
    static func requestTeamAccount(tabID: String, provider: AccountProvider, timeout: TimeInterval = 45) -> String? {
        let key = "\(tabID)~\(provider.rawValue)~\(UUID().uuidString)"
        let request = requestsDir.appendingPathComponent(key + ".request"), reply = requestsDir.appendingPathComponent(key + ".reply")
        try? FileManager.default.removeItem(at: reply)
        write(["provider": provider.rawValue], to: request)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: reply) {
                try? FileManager.default.removeItem(at: reply)
                return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["account"] as? String
            }
            usleep(200_000)
        }
        try? FileManager.default.removeItem(at: request)
        return nil
    }

    static func answerTeamRequest(_ key: String, account: String?) {
        write(["account": account], to: requestsDir.appendingPathComponent(key + ".reply"))
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Account folders

    static var nativeClaudeHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude")
    }

    static var nativeCodexHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
    }

    static var nativeGrokHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["GROK_HOME"] ?? NSHomeDirectory() + "/.grok")
    }

    static func nativeHome(_ provider: AccountProvider) -> URL {
        switch provider {
        case .claude: nativeClaudeHome
        case .codex: nativeCodexHome
        case .grok: nativeGrokHome
        }
    }

    /// Shared with your own login: conversations and agent state, plus your tools and settings.
    private static let claudeShared = ["projects", "sessions", "todos", "plans", "skills", "plugins", "hooks", "rules",
                                       "commands", "agents", "output-styles", "CLAUDE.md"]
    private static let codexShared = ["sessions", "archived_sessions", "history.jsonl", "skills", "rules", "plugins",
                                      "hooks", "prompts", "AGENTS.md"]
    /// The same list agmux shares. Never auth.json, its lock or the leader socket.
    private static let grokShared = ["sessions", "skills", "rules", "plugins", "hooks", "prompts", "AGENTS.md"]

    private static func shared(_ provider: AccountProvider) -> [String] {
        switch provider {
        case .claude: claudeShared
        case .codex: codexShared
        case .grok: grokShared
        }
    }

    /// Creates or refreshes a login's folder. Safe to run before every launch.
    @discardableResult
    static func prepareHome(_ id: String, provider: AccountProvider) throws -> URL {
        let home = home(id)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let native = nativeHome(provider)
        // A login that wrote its own sessions folder would lose it to the link made once yours
        // appears; Grok may never have run as you, so make yours first.
        if provider == .grok { try? fm.createDirectory(at: native.appendingPathComponent("sessions"), withIntermediateDirectories: true) }
        for name in shared(provider) {
            let target = native.appendingPathComponent(name), link = home.appendingPathComponent(name)
            guard fm.fileExists(atPath: target.path) else { continue }
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
            if (try? link.checkResourceIsReachable()) == true || (try? fm.attributesOfItem(atPath: link.path)) != nil {
                try? fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
        switch provider {
        case .claude:
            syncClaudeSettings(from: native, to: home)
            syncClaudeState(to: home)
        case .codex:
            try writeCodexConfig(from: native, to: home)
        case .grok:
            copyGrokConfig(from: native, to: home)
        }
        return home
    }

    /// Your config.toml (models, MCP servers, plugins), copied rather than linked: Grok rewrites
    /// it, and a login must not write yours.
    private static func copyGrokConfig(from native: URL, to home: URL) {
        guard let data = FileManager.default.contents(atPath: native.appendingPathComponent("config.toml").path) else { return }
        let url = home.appendingPathComponent("config.toml")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Grok shares one background "leader" per socket, signed in as whoever started it, so
    /// another login gets its own. Not in the login's folder: a socket path is limited to 104 bytes.
    static func grokLeaderSocket(_ home: URL) -> String {
        try? SessionPaths.prepareDirectory(SessionPaths.directory)
        return SessionPaths.grokLeader(home: home.path)
    }

    /// Your settings.json without anything that picks a login or API key.
    private static func syncClaudeSettings(from native: URL, to home: URL) {
        guard let data = try? Data(contentsOf: native.appendingPathComponent("settings.json")),
              var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        settings["apiKeyHelper"] = nil
        if var env = settings["env"] as? [String: Any] {
            for key in ClaudeAuthEnv.keys { env[key] = nil }
            env["CLAUDE_CONFIG_DIR"] = nil
            settings["env"] = env
        }
        guard let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: home.appendingPathComponent("settings.json"), options: .atomic)
    }

    /// Claude Code keeps onboarding, trusted folders and MCP servers in .claude.json next to the
    /// login. A login's own copy starts empty, so a switched session would stop at the theme
    /// picker or lose its tools; copy those over, never the account or its caches.
    static func syncClaudeState(to home: URL) {
        let nativeFile = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" } ?? NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: nativeFile),
              let native = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let url = home.appendingPathComponent(".claude.json")
        var mine = (FileManager.default.contents(atPath: url.path)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        for (key, value) in native where ClaudeAuthEnv.sharedStateKey(key) { mine[key] = value }
        guard let out = try? JSONSerialization.data(withJSONObject: mine, options: [.prettyPrinted]) else { return }
        try? out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Your config.toml, made to keep this login's token in a file and share the session catalog.
    private static func writeCodexConfig(from native: URL, to home: URL) throws {
        let text = (try? String(contentsOf: native.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let config = CodexConfig.forAccount(text, sqliteHome: native.path)
        try config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }
}
