import AgTermCore
import AppKit

/// Shell → Reopen Closed Tab: brings back the tab closed last, with its history, and resumes
/// the agent conversation it was running (`claude --resume <id>`, `codex resume <id>`, …).
extension MainWindowController {
    /// Saves `session` before its shell ends, so Reopen Closed Tab can bring it back. Cloud tabs
    /// aren't kept: their shells live on the cloud machine.
    func rememberClosed(_ session: TerminalSession) {
        guard !session.isCloud else { return }
        closedTabs.push(session.snapshot())
    }

    @objc func reopenClosedTab() {
        guard let saved = closedTabs.popLast() else { return NSSound.beep() }
        addTab(cwd: saved.cwd, restoring: saved)
    }

    /// Shell → Recently Closed → a tab: `representedObject` is its index in `closedTabs.tabs`.
    @objc func reopenClosedTabFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let saved = closedTabs.take(at: index) else { return NSSound.beep() }
        addTab(cwd: saved.cwd, restoring: saved)
    }
}

/// Shell → Recently Closed: the window's closed tabs, newest first, rebuilt each time it opens.
final class RecentlyClosedMenu: NSObject, NSMenuDelegate {
    private let closed: () -> ClosedTabs?

    init(closed: @escaping () -> ClosedTabs?) {
        self.closed = closed
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tabs = closed()?.tabs ?? []
        guard !tabs.isEmpty else {
            menu.addItem(NSMenuItem(title: "No Closed Tabs", action: nil, keyEquivalent: ""))
            return
        }
        for (index, tab) in tabs.enumerated().reversed() {
            let item = NSMenuItem(title: ClosedTabs.title(tab), action: #selector(MainWindowController.reopenClosedTabFromMenu(_:)),
                                  keyEquivalent: "")
            item.representedObject = index
            item.toolTip = tab.cwd
            menu.addItem(item)
        }
    }
}
