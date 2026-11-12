import AgTermCore
import AppKit

extension Notification.Name {
    /// Perch tabs opened or closed for some agterm tab; `PerchLink.shared.tabs` has the counts.
    static let perchTabsChanged = Notification.Name("agterm.perchTabsChanged")
}

/// agterm's side of Perch, the owner's browser: finding it, giving agents its MCP server,
/// showing which tabs' agents have Perch tabs open, bringing those forward, and opening web
/// links in it. Everything is off when Perch isn't installed.
final class PerchLink {
    static let shared = PerchLink()

    /// Settings → Agents switches, both on by default.
    static let mcpKey = "integrationPerch"
    static let openLinksKey = "perchOpenLinks"
    static let bundleID = "co.xanom.perch"

    /// Open Perch tabs per agterm tab id.
    private(set) var tabs: [String: Int] = [:]
    private var timer: Timer?
    private var lastModified: Date?

    /// The `perch` command (`Perch.cliCandidates`), or nil when Perch isn't installed.
    static func cli(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        Perch.cliCandidates(environment: environment, appPath: appURL?.path, home: NSHomeDirectory())
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var sessionsFile: URL {
        let home = ProcessInfo.processInfo.environment["PERCH_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perch")
        return home.appendingPathComponent("run/sessions.json")
    }

    static func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// The server to add for an agent started in a tab, unless the user turned it off or Perch
    /// isn't installed. When the agent already has a `perch` server: for Codex, one that
    /// `perch skill install` wrote is replaced by this tab's (a `-c` override wins over
    /// config.toml); otherwise it is kept, and still works in this tab's session because the
    /// tab exports PERCH_CLIENT and PERCH_SESSION, which `perch mcp` prefers to its flags.
    static func mcpServer(agent: String, tabID: String?, cwd: String, configured: Set<String>, codexConfig: () -> String = PerchLink.codexConfig) -> MCPServer? {
        guard enabled(mcpKey), let tabID, let session = Perch.sessionID(tabID), let cli = cli() else { return nil }
        guard Perch.addsServer(agent: agent, configured: configured, codexConfig: codexConfig) else { return nil }
        return Perch.mcpServer(cli: cli, agent: agent, tabID: session, folder: cwd)
    }

    static func codexConfig() -> String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        return (try? String(contentsOfFile: home + "/config.toml", encoding: .utf8)) ?? ""
    }

    /// Checks perchd's sessions file every two seconds; it is small and only read when it changed,
    /// or while it shows tabs (their perchd may have stopped without rewriting it).
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    private func refresh(force: Bool = false) {
        let file = Self.sessionsFile
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || modified != lastModified || !tabs.isEmpty else { return }
        lastModified = modified
        let next = (try? Data(contentsOf: file)).map { Perch.tabCounts($0, client: Perch.client) } ?? [:]
        guard next != tabs else { return }
        tabs = next
        NotificationCenter.default.post(name: .perchTabsChanged, object: self)
    }

    /// Brings the Perch tabs of agterm tab `tabID` forward.
    func focus(tabID: String) {
        guard let cli = Self.cli(), let session = Perch.sessionID(tabID) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["focus", "--client", Perch.client, "--session", session]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            DispatchQueue.main.async {
                if let app = Self.appURL {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    /// Closes the Perch tabs of agterm tab `tabID` (its session's tab group).
    func closeTabs(tabID: String) {
        guard let cli = Self.cli(), let args = Perch.endArguments(tabID: tabID) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(["PERCH_CLIENT": Perch.client]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            DispatchQueue.main.async { self.refresh(force: true) }
        }
    }

    /// Puts `perch` in agterm's bin folder (first on PATH in tabs) when Perch is installed and
    /// the shell would not find one of its own; removes agterm's link when Perch is gone.
    static func linkCommand(into bin: URL) {
        let link = bin.appendingPathComponent("perch")
        let ours = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        let target = enabled(mcpKey) ? cli() : nil
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), existing == target { return }
        if ours || !FileManager.default.fileExists(atPath: link.path) {
            try? FileManager.default.removeItem(at: link)
            if let target { try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target) }
        }
    }

    /// Opens a web link in Perch when it is installed and the setting is on. False means the
    /// caller should open it as usual.
    static func open(link: String) -> Bool {
        guard enabled(openLinksKey), Perch.isWebLink(link), let url = URL(string: link), let app = appURL else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
