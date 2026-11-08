#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Split panes and the tab sidebar: `AGTERM_PANES_CHECK=1 AGTERM_SELFTEST=<dir>`. Splits right
    /// (`panes-picker.png`), picks another tab for the empty pane, splits down into a new shell
    /// (`panes-split.png`), moves between panes, resizes, checks the save, shows the tabs on the
    /// left in both themes (`panes-sidebar-ink.png`, `panes-sidebar-paper.png`, and a sample agent
    /// card), fits many tabs, then unsplits, shows a tab beside another, and closes one.
    static func panesCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        UserDefaults.standard.set(false, forKey: MainWindowController.tabsOnLeftKey)
        controller.applyTabPlacement()
        window.setContentSize(NSSize(width: 1100, height: 620))
        controller.newTab()
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
            let other = controller.sessions[1]
            let tabs = controller.sessions.count
            controller.splitRight()
            report("split opens an empty pane", controller.focusedSession == nil && !controller.panePicker.isHidden
                   && window.firstResponder === controller.panePicker)
            report("empty pane lists the other tabs", controller.panePicker.choices.map(\.tabID) == [nil] + controller.sessions.dropFirst().map(\.tabID))
            snapshot(window, "\(outDir)/panes-picker.png")
            controller.selectCard(controller.sessions.firstIndex(of: other)!)
            let group = controller.selectedGroup!
            report("clicking a tab fills the empty pane", group.layout.panes == [first.tabID, other.tabID] && controller.focusedSession === other
                   && controller.panePicker.isHidden)
            report("no shell opened or closed", controller.sessions.count == tabs)
            controller.splitDown()
            controller.fillPicker(with: nil)
            let below = controller.focusedSession!
            report("new shell in the empty pane", group.layout.panes == [first.tabID, other.tabID, below.tabID]
                   && controller.sessions.count == tabs + 1)
            report("sessions follow tab order", controller.sessions.map(\.tabID) == controller.groups.flatMap(\.layout.panes))
            let models = controller.sessions.map(controller.tabModel)
            report("split tabs highlighted together", models.filter(\.selected).count == 3 && models.filter(\.focused).count == 1)
            let right = other
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
                    report("sidebar has every tab", controller.sidebar.cardsForTest.count == controller.sessions.count)
                    report("terminal beside the sidebar", first.view.convert(first.view.bounds, to: nil).minX >= TabSidebarView.width)
                    snapshot(window, "\(outDir)/panes-sidebar-ink.png")
                    report("margin beside the sidebar is painted", marginPainted(window, at: TabSidebarView.width + 6))
                    // A sample agent card, since a self-test can't run a real agent.
                    var agent = TabModel(topic: "Fix the login redirect", folder: "~/code/api",
                                         git: GitSummary(branch: "fix/redirect"),
                                         agentDiff: DiffCount(added: 42, removed: 7), status: .working, selected: false)
                    agent.agent = "Claude Code"
                    agent.model = "Opus 4.5"
                    agent.usage = "$1.24 · 38k tokens"
                    agent.agentSince = Date().addingTimeInterval(-14 * 60)
                    agent.logo = AgentLogo.image(for: "claude")
                    report("agent logos load", ["claude", "codex", "grok", "gemini", "kimi", "droid", "cline", "pi"]
                        .allSatisfy { AgentLogo.image(for: $0) != nil })
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

    /// Whether the window margins (`MarginView`) paint the column `x` points from the left,
    /// halfway down: in a see-through window an unpainted strip shows the desktop.
    private static func marginPainted(_ window: NSWindow, at x: CGFloat) -> Bool {
        guard let margin = window.contentView?.subviews.first(where: { $0 is MarginView }),
              let rep = margin.bitmapImageRepForCachingDisplay(in: margin.bounds) else { return false }
        margin.cacheDisplay(in: margin.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / margin.bounds.width
        return (rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0
    }

    /// One sidebar card drawn on the sidebar's color (the terminal's).
    private static func snapshotCard(_ model: TabModel, _ path: String) {
        let card = SidebarCardView(frame: NSRect(x: 0, y: 0, width: 248, height: SidebarCardView.height(for: model)))
        card.model = model
        let image = NSImage(size: card.bounds.size, flipped: false) { rect in
            Theme.bg.setFill()
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
        let tabs = controller.sessions.count
        for _ in 0..<10 { controller.newTab() }
        controller.focus(first.tabID)
        after(0.4) {
            let densities = controller.sidebar.cardsForTest.compactMap { ($0 as? SidebarCardView)?.density }
            report("many tabs drop details to fit", densities.allSatisfy { $0 != .full }, "\(densities.first.map { "\($0)" } ?? "none")")
            controller.unsplit()
            report("unsplit keeps every tab", controller.sessions.count == tabs + 10 && controller.groups.count == controller.sessions.count, "")
            let lone = controller.sessions.last!
            controller.show(lone, beside: .columns)
            report("show a tab beside another", controller.selectedGroup?.layout.panes == [first.tabID, lone.tabID], "")
            controller.closeTab()
            after(0.4) {
                report("closing a tab in a split keeps the other", controller.selectedGroup?.layout.panes == [first.tabID]
                       && controller.sessions.count == tabs + 9, "")
                done()
            }
        }
    }
}
#endif
