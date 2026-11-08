#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The command palette: `AGTERM_PALETTE_CHECK=1 AGTERM_SELFTEST=<dir>`. Opens it on Ink
    /// (`palette-ink.png`) and Paper (`palette-paper.png`, typed "spl"), checks it lists menu
    /// commands with shortcuts and the other tabs, runs Split Right from it, then switches tabs with it.
    static func paletteCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 1000, height: 560))
        controller.newTab()
        controller.select(0)
        controller.showWindow(nil)
        let theme = Preferences.shared.appearance.themeID
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: palette: \(name):", ok ? "ok" : "FAIL", detail)
            if !ok { failed = true }
        }
        let palette = controller.commandPalette
        Preferences.shared.update { $0.themeID = "ink" }
        after(1.0) {
            controller.toggleCommandPalette()
            let titles = palette.results.map(\.item.title)
            report("opens focused", palette.superview != nil && window.firstResponder === palette.subviews.compactMap { $0 as? NSTextField }.first?.currentEditor())
            report("lists commands", titles.contains("Split Right") && titles.contains("New Tab") && !titles.contains("Command Palette…"))
            report("lists the other tab first", palette.results.first?.item.detail.hasPrefix("Tab · ") == true && titles.count > 20, "\(titles.count) entries")
            let split = palette.results.first { $0.item.title == "Split Right" }?.item
            report("shows shortcuts and menus", split?.shortcut == "⌘D" && split?.detail == "Shell", "\(split?.shortcut ?? "-") \(split?.detail ?? "-")")
        }
        after(1.4) {
            snapshot(window, "\(outDir)/palette-ink.png")
            controller.toggleCommandPalette()
            report("closes again", palette.superview == nil && window.firstResponder === controller.focusedSession?.view)
            Preferences.shared.update { $0.themeID = "paper" }
        }
        after(1.9) {
            controller.toggleCommandPalette()
            palette.selfTestType("spl")
            report("fuzzy finds Split Right first", palette.results.first?.item.title == "Split Right",
                   palette.results.prefix(3).map(\.item.title).joined(separator: ", "))
        }
        after(2.3) {
            snapshot(window, "\(outDir)/palette-paper.png")
            let tabs = controller.sessions.count
            palette.selfTestRun()
            report("runs the command", palette.superview == nil && controller.focusedSession == nil
                   && controller.sessions.count == tabs)
            controller.unsplitTab()

            let target = controller.sessions[1]
            target.name = "palette-target"
            controller.select(0)
            controller.toggleCommandPalette()
            palette.selfTestType("pltarget")
            palette.selfTestRun()
            report("switches tabs", controller.focusedSession === target)

            Preferences.shared.update { $0.themeID = theme }
            print("selftest: palette:", failed ? "FAILED" : "passed")
            after(0.5) { exit(failed ? 1 : 0) }
        }
    }
}
#endif
