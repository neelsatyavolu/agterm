#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Keep Mac awake: `AGTERM_AWAKE_CHECK=1 AGTERM_SELFTEST=<dir>`. With the setting on, a working
    /// agent holds an idle-sleep assertion (`pmset -g assertions` lists it) and an idle one lets go;
    /// with it off nothing is held. Never installs or runs the closed-lid helper. Snapshots the
    /// Settings → Agents section in Ink and Paper (`awake-settings-ink.png`, `awake-settings-paper.png`).
    static func awakeCheck(outDir: String) {
        let awake = KeepAwake.shared
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: KeepAwake.enabledKey), defaults.object(forKey: KeepAwake.closedLidKey))
        let theme = Preferences.shared.appearance.themeID
        var failed = false
        func report(_ name: String, _ ok: Bool) {
            print("selftest: awake: \(name):", ok ? "ok" : "FAIL")
            if !ok { failed = true }
        }
        func held() -> Bool {
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["-g", "assertions"]
            let out = Pipe()
            pmset.standardOutput = out
            try? pmset.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            pmset.waitUntilExit()
            return text.contains("pid \(getpid())(") && text.contains("agterm: agents are working")
        }

        defaults.set(true, forKey: KeepAwake.enabledKey)
        defaults.set(false, forKey: KeepAwake.closedLidKey)
        awake.update(agentsBusy: true)
        report("working agent holds idle sleep", held())
        awake.update(agentsBusy: false)
        report("idle lets go", !held())
        defaults.set(false, forKey: KeepAwake.enabledKey)
        awake.update(agentsBusy: true)
        report("off holds nothing", !held())
        awake.update(agentsBusy: false)
        let menu = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.action == #selector(KeepAwake.toggleEnabled(_:)) }
        report("agterm menu has the toggle", menu?.target === awake)
        if let menu { awake.toggleEnabled(menu) }
        report("menu turns it on", awake.enabled)

        let settings = SettingsWindowController.shared
        settings.show(pane: "Agents")
        Preferences.shared.update { $0.themeID = "ink" }
        after(0.8) { scrollSettingsToBottom(); }
        after(1.4) {
            snapshotSettings("\(outDir)/awake-settings-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
        }
        after(2.2) {
            scrollSettingsToBottom()
            snapshotSettings("\(outDir)/awake-settings-paper.png")
            Preferences.shared.update { $0.themeID = theme }
            defaults.set(saved.0, forKey: KeepAwake.enabledKey)
            defaults.set(saved.1, forKey: KeepAwake.closedLidKey)
            print("selftest: awake:", failed ? "FAILED" : "passed")
            exit(failed ? 1 : 0)
        }
    }

    /// The Sleep section sits below the fold of the Agents pane.
    private static func scrollSettingsToBottom() {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let content = SettingsWindowController.shared.window?.contentView else { return }
        for scroll in scrollViews(content) {
            guard let document = scroll.documentView else { continue }
            let target = NSPoint(x: 0, y: document.isFlipped ? max(document.bounds.height - scroll.contentView.bounds.height, 0) : 0)
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
#endif
