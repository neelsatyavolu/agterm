import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        AgentIntegration.installShellIntegration()
        AgentTerminalView.installScrollSmoothing()
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
        askForDiskAccessIfNeeded()
        TeamsSync.shared.start()
        RemoteClient.shared.startIfEnabled()
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

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveWorkspaceForQuit()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller?.window?.attachedSheet != nil { return .terminateCancel }
        let running = controller?.runningPrograms ?? []
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit agterm?"
        alert.informativeText = "Still running:\n" + running.joined(separator: "\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("agterm", [
            item("About agterm", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings), ","),
            updatesItem(),
            .separator(),
            item("Hide agterm", #selector(NSApplication.hide(_:)), "h"),
            item("Quit agterm", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Shell", [
            item("New Tab", #selector(MainWindowController.newTab), "t"),
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

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
