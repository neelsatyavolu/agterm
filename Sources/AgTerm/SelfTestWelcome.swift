#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The 1.2 welcome window: `AGTERM_WELCOME_CHECK=1 AGTERM_SELFTEST=<dir>`. It opens on the
    /// update into 1.2 only, and snapshots in Ink and Paper (`welcome-ink.png`, `welcome-paper.png`).
    static func welcomeCheck(_ controller: MainWindowController, outDir: String) {
        var failed = false
        func report(_ name: String, _ ok: Bool) {
            print("selftest: welcome: \(name):", ok ? "ok" : "FAIL")
            if !ok { failed = true }
        }
        report("shows on 1.1.7 → 1.2.0", Changelog.crossed(Welcome.milestone, lastSeen: "1.1.7", current: "1.2.0"))
        report("not again on 1.2.0 → 1.2.1", !Changelog.crossed(Welcome.milestone, lastSeen: "1.2.0", current: "1.2.1"))
        let toggles = Welcome.groups.flatMap(\.features).filter { if case .toggle = $0.control { return true } else { return false } }
        report("has switches for keep awake, consult and usage counts", toggles.count == 3)
        let theme = Preferences.shared.appearance.themeID
        controller.showWindow(nil)
        Preferences.shared.update { $0.themeID = "ink" }
        WelcomeWindowController.shared.show(over: controller)
        after(1) {
            guard let window = WelcomeWindowController.shared.window else { exit(1) }
            report("window is up", window.isVisible)
            snapshot(window, "\(outDir)/welcome-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
            WelcomeWindowController.shared.show(over: controller)
            after(1) {
                snapshot(window, "\(outDir)/welcome-paper.png")
                Preferences.shared.update { $0.themeID = theme }
                print("selftest: welcome:", failed ? "FAILED" : "all ok")
                exit(failed ? 1 : 0)
            }
        }
    }
}
#endif
