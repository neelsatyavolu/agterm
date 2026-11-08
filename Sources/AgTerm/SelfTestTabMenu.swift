#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Right-clicking a tab: `AGTERM_TABMENU_CHECK=1 AGTERM_SELFTEST=<dir>`. Lists the menu, renames
    /// the first tab through the real sheet (`tab-renamed.png`), checks the name is saved, then
    /// clears it and the program's title comes back, then checks pinning (`pinCheck`).
    static func tabMenuCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 900, height: 300))
        controller.newTab()
        controller.select(0)
        controller.showWindow(nil)
        let session = controller.sessions[0]
        after(1.5) {
            print("selftest: tab menu:", controller.tabMenuForTest(0).items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
            let automatic = session.topic
            rename(controller, to: "  api server\n") {
                print("selftest: tab menu: renamed to", "[\(session.topic)]", "| saved name:", session.snapshot().name ?? "none")
                snapshot(window, "\(outDir)/tab-renamed.png")
                rename(controller, to: "   ") {
                    print("selftest: tab menu: cleared, title back:", session.topic == automatic, "| name:", session.name ?? "none")
                    pinCheck(controller, outDir: outDir)
                }
            }
        }
    }

    /// Pins the last of three tabs from its menu: it moves to the top, stays selected, is saved
    /// pinned, and shows a pin in the sidebar (`tab-pinned-ink.png`, `tab-pinned-paper.png`). A tab
    /// dragged above it goes back below; unpinning puts it after the pinned ones.
    private static func pinCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        UserDefaults.standard.set(true, forKey: MainWindowController.tabsOnLeftKey)
        controller.applyTabPlacement()
        controller.newTab()
        let last = controller.sessions[2]
        controller.select(2)
        guard let item = controller.tabMenuForTest(2).items.first(where: { $0.title == "Pin Tab" }), let action = item.action else {
            print("selftest: pin: FAIL no Pin Tab item")
            exit(1)
        }
        NSApp.sendAction(action, to: item.target, from: item)
        controller.renderForTest()
        let ok = controller.sessions.first === last && controller.selectedGroup?.layout.contains(last.tabID) == true
            && last.snapshot().pinned == true
            && controller.tabMenuForTest(0).items.contains { $0.title == "Unpin Tab" }
        print("selftest: pin: pinned tab first, selected and saved:", ok ? "ok" : "FAIL")
        let theme = Preferences.shared.appearance.themeID
        after(0.4) {
            snapshot(window, "\(outDir)/tab-pinned-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
            after(0.4) {
                snapshot(window, "\(outDir)/tab-pinned-paper.png")
                Preferences.shared.update { $0.themeID = theme }
                controller.moveTab(from: 2, to: 0)
                let kept = controller.sessions.first === last
                print("selftest: pin: tab dragged above a pinned one goes back below:", kept ? "ok" : "FAIL")
                controller.setPinned(last, false)
                let unpinned = controller.sessions.first === last && last.snapshot().pinned == nil
                print("selftest: pin: unpinned tab stays in place:", unpinned ? "ok" : "FAIL")
                UserDefaults.standard.set(false, forKey: MainWindowController.tabsOnLeftKey)
                exit(ok && kept && unpinned ? 0 : 1)
            }
        }
    }

    /// Opens Rename Tab… for the selected tab, types `text` and presses Rename.
    private static func rename(_ controller: MainWindowController, to text: String, then next: @escaping () -> Void) {
        controller.renameTab()
        after(0.5) {
            guard let sheet = controller.window?.attachedSheet, let content = sheet.contentView,
                  let field = subviews(of: content).compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
                  let button = subviews(of: content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Rename" }) else {
                print("selftest: tab menu: no rename sheet")
                exit(1)
            }
            field.stringValue = text
            button.performClick(nil)
            after(0.5) {
                controller.renderForTest()
                next()
            }
        }
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews)
    }
}
#endif
