#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Split panes and the tab sidebar: `AGTERM_PANES_CHECK=1 AGTERM_SELFTEST=<dir>`. Splits a tab
    /// right then down (`panes-split.png`), moves between panes, drags nothing but sets a ratio,
    /// checks the save holds the arrangement, shows the tabs on the left in both themes
    /// (`panes-sidebar-ink.png`, `panes-sidebar-paper.png`), then closes a pane and a tab.
    static func panesCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        UserDefaults.standard.set(false, forKey: MainWindowController.tabsOnLeftKey)
        controller.applyTabPlacement()
        window.setContentSize(NSSize(width: 1100, height: 620))
        controller.newTab()
        controller.select(0)
        controller.showWindow(nil)
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: panes: \(name):", ok ? "ok" : "FAIL", detail)
            if !ok { failed = true }
        }
        after(1.0) {
            let first = controller.focusedSession!
            controller.splitRight()
            let right = controller.focusedSession!
            controller.splitDown()
            let below = controller.focusedSession!
            let group = controller.selectedGroup!
            report("three panes in one tab", controller.groups.count == 2 && group.layout.panes == [first.tabID, right.tabID, below.tabID],
                   "tabs: \(controller.groups.count)")
            report("sessions follow tab order", controller.sessions.map(\.tabID) == group.layout.panes + controller.groups[1].layout.panes)
            report("new pane is typed in", window.firstResponder === below.view)
            let frames = [first, right, below].map { $0.view.frame }
            report("panes side by side", frames[0].maxX < frames[1].minX && frames[1].maxY < frames[2].minY,
                   frames.map { NSStringFromRect($0) }.joined(separator: " "))

            controller.selectPaneLeft()
            report("pane left", controller.focusedSession === first)
            controller.selectPaneRight()
            report("pane right", controller.focusedSession === right)
            controller.nextPane()
            report("next pane", controller.focusedSession === below)
            window.makeFirstResponder(first.view)
            after(0.2) {
                report("clicking a pane focuses it", controller.focusedSession === first)
                let before = first.view.frame.width
                controller.resizePanes([], 0.3)
                report("divider resizes", first.view.frame.width < before, "\(before) → \(first.view.frame.width)")
                snapshot(window, "\(outDir)/panes-split.png")

                controller.saveWorkspace()
                let saved = WorkspaceStore.load()
                report("save keeps the panes", saved?.groups?.first?.layout.panes == group.layout.panes
                       && saved?.tabs.count == controller.sessions.count)
                report("save keeps the focused pane", saved.map { $0.tabs[$0.selected].tabID } == first.tabID)

                controller.toggleTabsOnLeft()
                after(0.6) {
                    report("sidebar shown", !controller.sidebar.isHidden && controller.tabBar.isHidden)
                    report("sidebar has every tab", controller.sidebar.cardsForTest.count == controller.groups.count)
                    report("terminal beside the sidebar", first.view.convert(first.view.bounds, to: nil).minX >= TabSidebarView.width)
                    snapshot(window, "\(outDir)/panes-sidebar-ink.png")
                    // A sample agent card, since a self-test can't run a real agent.
                    var agent = TabModel(topic: "Fix the login redirect", folder: "~/code/api",
                                         git: GitSummary(branch: "fix/redirect"),
                                         agentDiff: DiffCount(added: 42, removed: 7), status: .working, selected: false)
                    agent.agent = "Claude Code"
                    agent.model = "Opus 4.5"
                    agent.usage = "$1.24 · 38k tokens"
                    agent.agentSince = Date().addingTimeInterval(-14 * 60)
                    snapshotCard(agent, "\(outDir)/panes-card-ink.png")
                    let theme = Preferences.shared.appearance.themeID
                    Preferences.shared.update { $0.themeID = "paper" }
                    after(0.4) {
                        snapshot(window, "\(outDir)/panes-sidebar-paper.png")
                        snapshotCard(agent, "\(outDir)/panes-card-paper.png")
                        Preferences.shared.update { $0.themeID = theme }
                        closeChecks(controller, first: first, report: report) {
                            controller.toggleTabsOnLeft()
                            exit(failed ? 1 : 0)
                        }
                    }
                }
            }
        }
    }

    /// One sidebar card drawn on the sidebar's color.
    private static func snapshotCard(_ model: TabModel, _ path: String) {
        let card = SidebarCardView(frame: NSRect(x: 0, y: 0, width: 248, height: SidebarCardView.height(for: model)))
        card.model = model
        let image = NSImage(size: card.bounds.size, flipped: false) { rect in
            Theme.chrome.setFill()
            rect.fill()
            return true
        }
        let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: card.bounds)
        NSGraphicsContext.restoreGraphicsState()
        card.cacheDisplay(in: card.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func closeChecks(_ controller: MainWindowController, first: TerminalSession,
                                    report: @escaping (String, Bool, String) -> Void, then done: @escaping () -> Void) {
        controller.focus(first.tabID)
        controller.closePane()
        after(0.4) {
            let group = controller.selectedGroup!
            report("closing a pane keeps the tab", controller.groups.count == 2 && group.layout.panes.count == 2, "")
            report("neighbor takes focus", controller.focusedSession.map { group.layout.contains($0.tabID) } == true, "")
            controller.closeTab()
            after(0.4) {
                report("closing the tab ends its panes", controller.groups.count == 1 && controller.sessions.count == 1, "")
                done()
            }
        }
    }
}
#endif
