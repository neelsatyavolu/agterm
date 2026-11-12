#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Perch's marks: `AGTERM_PERCH_CHECK=1 AGTERM_SELFTEST=<dir> PERCH_HOME=<scratch dir>`. Writes a
    /// perchd sessions file giving the first tab two Perch tabs, then checks the tab menu offers to
    /// show and close them and snapshots the globe in the tab bar and the sidebar, in Ink and Paper
    /// (`perch-bar-ink.png`, `perch-bar-paper.png`, `perch-sidebar-ink.png`, `perch-sidebar-paper.png`).
    static func perchCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 900, height: 320))
        controller.newTab()
        controller.newTab()
        controller.select(0)
        controller.showWindow(nil)
        let tab = controller.sessions[0].tabID
        let file = PerchLink.sessionsFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
            {"version":1,"pid":\(ProcessInfo.processInfo.processIdentifier),"sessions":[
              {"client":"agterm","session":"\(tab)","agent":"claude","title":"perch","label":"claude · perch","tabs":2,"asleep":false}]}
            """
        try? json.write(to: file, atomically: true, encoding: .utf8)
        PerchLink.shared.start()
        let theme = Preferences.shared.appearance.themeID
        after(3) {
            let counted = PerchLink.shared.tabs[tab] == 2
            print("selftest: perch: sessions file read:", counted ? "ok" : "FAIL \(PerchLink.shared.tabs)")
            let items = controller.tabMenuForTest(0).items.map(\.title)
            let menu = items.contains("Show 2 Perch Tabs") && items.contains("Close 2 Perch Tabs")
            print("selftest: perch: tab menu offers show and close:", menu ? "ok" : "FAIL \(items)")
            let other = controller.tabMenuForTest(1).items.map(\.title)
            print("selftest: perch: a tab without Perch tabs has no Perch items:", other.contains { $0.contains("Perch") } ? "FAIL" : "ok")
            UserDefaults.standard.set(false, forKey: MainWindowController.tabsOnLeftKey)
            controller.applyTabPlacement()
            controller.renderForTest()
            shoot(window, outDir, "perch-bar", theme: theme) {
                UserDefaults.standard.set(true, forKey: MainWindowController.tabsOnLeftKey)
                controller.applyTabPlacement()
                controller.renderForTest()
                shoot(window, outDir, "perch-sidebar", theme: theme) {
                    try? FileManager.default.removeItem(at: file)
                    print("selftest: perch: done")
                    UserDefaults.standard.set(false, forKey: MainWindowController.tabsOnLeftKey)
                    exit(counted && menu ? 0 : 1)
                }
            }
        }
    }

    /// Snapshots `window` in Ink then Paper as `<name>-ink.png` and `<name>-paper.png`, then puts `theme` back.
    private static func shoot(_ window: NSWindow, _ outDir: String, _ name: String, theme: String, then: @escaping () -> Void) {
        Preferences.shared.update { $0.themeID = "ink" }
        after(0.5) {
            snapshot(window, "\(outDir)/\(name)-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
            after(0.5) {
                snapshot(window, "\(outDir)/\(name)-paper.png")
                Preferences.shared.update { $0.themeID = theme }
                then()
            }
        }
    }
}
#endif
