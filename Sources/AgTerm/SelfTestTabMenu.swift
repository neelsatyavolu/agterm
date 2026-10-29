#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Right-clicking a tab: `AGTERM_TABMENU_CHECK=1 AGTERM_SELFTEST=<dir>`. Lists the menu, renames
    /// the first tab through the real sheet (`tab-renamed.png`), checks the name is saved, then
    /// clears it and the program's title comes back.
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
                    exit(0)
                }
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
