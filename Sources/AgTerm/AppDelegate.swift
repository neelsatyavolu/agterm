import AgTermCore
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private var shortcutObserver: NSObjectProtocol?
    /// Set by Quit and End Sessions: this quit ends the tabs' shells instead of leaving them running.
    private var endSessionsOnQuit = false
    private weak var quitAndEndItem: NSMenuItem?
    private static let quitAndEndShortcut = KeyShortcut(key: "q", modifiers: [.command, .option])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything this run could save tabs, so a first launch never looks like an update.
        let previousInstall = FileManager.default.fileExists(atPath: WorkspaceStore.fileURL.path)
        NSApp.mainMenu = buildMenu()
        AgentIntegration.installShellIntegration()
        AgentTerminalView.installScrollSmoothing()
        QuickCommandRunner.shared.warmUp()
        Notifier.shared.start()
        let controller = MainWindowController()
        self.controller = controller
        #if DEBUG
        if let outDir = ProcessInfo.processInfo.environment["AGTERM_SELFTEST"] {
            SelfTest.run(controller, outDir: outDir)
            return
        }
        #endif
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        WhatsNew.showIfUpdated(in: controller, previousInstall: previousInstall)
        askForDiskAccessIfNeeded()
        TeamsSync.shared.start()
        TeamAccounts.shared.start()
        UsageMonitor.shared.start()
        RemoteClient.shared.startIfEnabled()
    }

    /// Every other installed agent, listed when the menu opens (the PATH is found after launch).
    private let moreAgents = MoreAgentsMenu()

    private func moreAgentsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "New Tab With Agent", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "New Tab With Agent")
        menu.delegate = moreAgents
        item.submenu = menu
        return item
    }

    private func updatesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        item.target = Updater.shared
        item.isHidden = !Updater.shared.isAvailable
        return item
    }

    @objc func showSettings() {
        SettingsWindowController.shared.show()
    }

    @objc func showWhatsNew() {
        guard let controller else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        WhatsNew.showAll(in: controller)
    }

    /// Asked on every launch until granted; "Later" keeps the app usable for this session.
    private func askForDiskAccessIfNeeded() {
        guard DiskAccessMonitor.shared.status == .denied, let window = controller?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Give agterm Full Disk Access"
        alert.informativeText = """
            Agents and tools you run in agterm get the same access as agterm. Without Full Disk Access, \
            macOS blocks them from Desktop, Documents, Mail and other apps' data, or asks again and again.

            In System Settings, turn on agterm under Full Disk Access. If it isn't listed, drag agterm \
            from the Finder window into the list. agterm asks again at launch until it has access.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { DiskAccessMonitor.openSystemSettings() }
        }
    }

    /// Quitting (⌘Q, an update's relaunch) leaves the tabs' shells running in the helper for the
    /// next launch; Quit and End Sessions ends them. Agents on a team login keep it only across
    /// an update's relaunch: nothing renews the loan while agterm is closed.
    func applicationWillTerminate(_ notification: Notification) {
        // Read the tabs before the quit lets go of them.
        let keptTabs = endSessionsOnQuit || !Updater.shared.isRelaunchingForUpdate ? nil : controller?.keptTabIDs
        controller?.quit(endingSessions: endSessionsOnQuit)
        TeamAccounts.shared.giveBackAll(keepingAgentsIn: keptTabs)
    }

    @objc func quitAndEndSessions() {
        endSessionsOnQuit = true
        NSApp.terminate(nil)
    }

    /// Asks only about programs the quit would stop: those in in-process tabs, or every one when
    /// ending sessions, and agents on a team login unless an update is relaunching agterm.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = shouldTerminate()
        if reply == .terminateCancel { endSessionsOnQuit = false }
        return reply
    }

    private func shouldTerminate() -> NSApplication.TerminateReply {
        if controller?.window?.attachedSheet != nil { return .terminateCancel }
        let running = controller?.runningPrograms(endingSessions: endSessionsOnQuit) ?? []
        // Ending sessions lists every program already; an update's relaunch keeps team logins.
        let stopsKeptTeamAgents = !endSessionsOnQuit && !Updater.shared.isRelaunchingForUpdate
        let teamAgents = stopsKeptTeamAgents ? controller?.teamAgentsStopping(TeamAccounts.shared.teamAgentsByTab) ?? [] : []
        guard !running.isEmpty || !teamAgents.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit agterm?"
        alert.informativeText = [running.isEmpty ? nil : "Still running:\n" + running.joined(separator: "\n"),
                                 teamAgents.isEmpty ? nil : teamAgents.joined(separator: "\n")]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("agterm", [
            item("About agterm", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("What's New…", #selector(AppDelegate.showWhatsNew)),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings), ","),
            updatesItem(),
            .separator(),
            item("Hide agterm", #selector(NSApplication.hide(_:)), "h"),
            item("Quit agterm", #selector(NSApplication.terminate(_:)), "q"),
            quitAndEndSessionsItem(),
        ]))
        main.addItem(submenu("Shell", [
            item("New Tab", #selector(MainWindowController.newTab), "t"),
            newAgentTabItem(),
        ] + Self.agentItems([.claude, .codex, .grok]) + [
            moreAgentsItem(),
            .separator(),
            item("Write a Command…", #selector(MainWindowController.toggleCommandBar), "k"),
            .separator(),
            item("Close Tab", #selector(MainWindowController.closeTab), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("View", [
            item("Bigger", #selector(MainWindowController.biggerFont), "="),
            item("Smaller", #selector(MainWindowController.smallerFont), "-"),
            item("Actual Size", #selector(MainWindowController.resetFont), "0"),
        ]))
        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Show Next Tab", #selector(MainWindowController.nextTab), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(MainWindowController.previousTab), "[", [.command, .shift]),
            item("Move Tab Left", #selector(MainWindowController.moveTabLeft), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .shift]),
            item("Move Tab Right", #selector(MainWindowController.moveTabRight), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .shift]),
            item("Next Tab", #selector(MainWindowController.nextTab), "\t", [.control]),
            item("Previous Tab", #selector(MainWindowController.previousTab), "\t", [.control, .shift]),
            .separator(),
        ]
        for n in 1...9 {
            let tab = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(MainWindowController.selectTabFromMenu(_:)), "\(n)")
            tab.tag = n
            windowItems.append(tab)
        }
        let windowMenu = submenu("Window", windowItems)
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)
        return main
    }

    /// "New <agent> Tab" items. Claude Code, Codex and Grok keep ⌥⌘1–3 wherever they appear.
    static func agentItems(_ agents: [AgentKind], target: AnyObject? = nil, shortcuts: Bool = true) -> [NSMenuItem] {
        agents.map { agent in
            let item = NSMenuItem(title: "New \(agent.title) Tab", action: #selector(MainWindowController.newAgentTabFromMenu(_:)),
                                  keyEquivalent: "")
            if shortcuts, let index = [AgentKind.claude, .codex, .grok].firstIndex(of: agent) {
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = [.command, .option]
            }
            item.representedObject = agent.id
            item.target = target
            return item
        }
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// Its shortcut is set in Settings → Agents and follows changes there.
    private func newAgentTabItem() -> NSMenuItem {
        let item = item("New Agent Tab", #selector(MainWindowController.newDefaultAgentTab))
        item.setShortcut(AgentIntegration.newAgentTabShortcut)
        shortcutObserver = NotificationCenter.default.addObserver(forName: .agtermShortcutChanged, object: nil, queue: .main) { [weak self, weak item] _ in
            item?.setShortcut(AgentIntegration.newAgentTabShortcut)
            self?.updateQuitAndEndShortcut()
        }
        return item
    }

    /// ⌥⌘Q, unless New Agent Tab was given ⌥⌘Q before this item existed: then it has none, so
    /// that key never ends every session by surprise.
    private func quitAndEndSessionsItem() -> NSMenuItem {
        let item = item("Quit and End Sessions", #selector(AppDelegate.quitAndEndSessions))
        quitAndEndItem = item
        updateQuitAndEndShortcut()
        return item
    }

    private func updateQuitAndEndShortcut() {
        let taken = AgentIntegration.newAgentTabShortcut == Self.quitAndEndShortcut
        quitAndEndItem?.setShortcut(Self.quitAndEndShortcut)
        if taken { quitAndEndItem?.keyEquivalent = "" }
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

private final class MoreAgentsMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let agents = AgentIntegration.installedAgents() else {
            menu.addItem(NSMenuItem(title: "Looking for installed agents…", action: nil, keyEquivalent: ""))
            return
        }
        AppDelegate.agentItems(agents, shortcuts: false).forEach(menu.addItem)
    }
}
