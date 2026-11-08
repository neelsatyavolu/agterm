import AgTermCore
import AppKit

/// A tab: one or more panes, each a shell (`TerminalSession`, named by its tab ID), and the
/// one you type in.
final class PaneGroup {
    var layout: PaneNode
    var focused: String

    init(layout: PaneNode, focused: String) {
        self.layout = layout
        self.focused = focused
    }

    convenience init(_ session: TerminalSession) {
        self.init(layout: .pane(session.tabID), focused: session.tabID)
    }
}

/// Split panes and the tab sidebar.
extension MainWindowController {
    static let tabsOnLeftKey = "tabsOnLeft"

    // MARK: Splitting

    /// ⌘D: a new shell beside the pane you're typing in, in its folder.
    @objc func splitRight() { split(.columns) }
    /// ⇧⌘D: a new shell below it.
    @objc func splitDown() { split(.rows) }

    @objc func splitRightFromMenu(_ sender: NSMenuItem) { splitFromMenu(sender, .columns) }
    @objc func splitDownFromMenu(_ sender: NSMenuItem) { splitFromMenu(sender, .rows) }

    private func splitFromMenu(_ sender: NSMenuItem, _ axis: PaneAxis) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        focus(session.tabID)
        split(axis)
    }

    // MARK: Moving between panes

    @objc func selectPaneLeft() { focusNeighbor(.left) }
    @objc func selectPaneRight() { focusNeighbor(.right) }
    @objc func selectPaneAbove() { focusNeighbor(.up) }
    @objc func selectPaneBelow() { focusNeighbor(.down) }

    /// ⌘] and ⌘[: the tab's panes in order, wrapping around.
    @objc func nextPane() { cyclePane(by: 1) }
    @objc func previousPane() { cyclePane(by: -1) }

    private func focusNeighbor(_ direction: PaneDirection) {
        guard let group = selectedGroup,
              let next = group.layout.neighbor(of: group.focused, direction, in: container.layoutSpace) else { return }
        focus(next)
    }

    private func cyclePane(by step: Int) {
        guard let group = selectedGroup else { return }
        let panes = group.layout.panes
        guard panes.count > 1, let index = panes.firstIndex(of: group.focused) else { return }
        focus(panes[(index + step + panes.count) % panes.count])
    }

    /// Clicking into a pane makes it the one the tab shows as focused.
    func observeFocus() {
        focusObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            DispatchQueue.main.async {
                guard let self, let view = window.firstResponder as? AgentTerminalView,
                      let group = self.selectedGroup,
                      let session = self.sessions.first(where: { $0.view === view }),
                      group.layout.contains(session.tabID), group.focused != session.tabID else { return }
                self.focus(session.tabID)
            }
        }
    }

    func resizePanes(_ path: [Int], _ ratio: Double) {
        guard let group = selectedGroup else { return }
        group.layout = group.layout.settingRatio(ratio, at: path)
        showSelectedPanes()
    }

    // MARK: Tabs on the left

    var tabsOnLeft: Bool { UserDefaults.standard.bool(forKey: Self.tabsOnLeftKey) }

    /// View → Tabs on the Left: the sidebar with each tab's agent, model and spend, or the tab
    /// bar along the top.
    @objc func toggleTabsOnLeft() {
        UserDefaults.standard.set(!tabsOnLeft, forKey: Self.tabsOnLeftKey)
        applyTabPlacement()
        render()
    }

    func applyTabPlacement() {
        let left = tabsOnLeft
        NSLayoutConstraint.deactivate(left ? topLayout : sideLayout)
        NSLayoutConstraint.activate(left ? sideLayout : topLayout)
        tabBar.isHidden = left
        sidebar.isHidden = !left
        titleStrip.isHidden = !left
        window?.contentView?.layoutSubtreeIfNeeded()
        focusedSession?.pushSize()
    }

    func setCloudButton(_ cloud: TabBarView.Cloud) {
        tabBar.cloud = cloud
        sidebar.cloud = cloud
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleTabsOnLeft):
            item.state = tabsOnLeft ? .on : .off
            return true
        case #selector(selectPaneLeft), #selector(selectPaneRight), #selector(selectPaneAbove), #selector(selectPaneBelow),
             #selector(nextPane), #selector(previousPane):
            return (selectedGroup?.layout.panes.count ?? 0) > 1
        default:
            return true
        }
    }

    // MARK: Building the cards

    /// What a tab's card shows: its focused pane, the most pressing status among its panes, and
    /// the agent's details for the sidebar.
    func tabModel(_ group: PaneGroup, selected: Bool) -> TabModel? {
        let panes = group.layout.panes.compactMap(session(_:))
        guard let s = session(group.focused) ?? panes.first else { return nil }
        let moving = cloudState.moving[ObjectIdentifier(s)]
        var model = TabModel(topic: s.topic, folder: s.folder, git: s.git,
                             agentDiff: s.agentDiff.map { DiffCount(added: $0.added, removed: $0.removed) },
                             status: Self.mostPressing(panes.map(\.status)), selected: selected, inCloud: s.isCloud,
                             moving: moving?.label, movingProgress: moving?.progress)
        model.agent = s.agentName.map { AgentKind.named($0)?.title ?? $0 }
        model.model = s.agentUsage?.model.flatMap(ModelName.short)
        model.usage = s.agentUsage.flatMap { usage in
            let parts = [UsageText.cost(usage.costUSD, incomplete: usage.costIncomplete), UsageText.tokens(usage.tokens)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        model.agentSince = s.agentName == nil ? nil : s.agentStartedAt
        model.program = s.agentName == nil && s.foregroundName != s.shellName ? s.foregroundName : nil
        model.panes = panes.count
        return model
    }

    /// A pane waiting on you outranks one working, then one done.
    private static func mostPressing(_ statuses: [TabStatus]) -> TabStatus {
        let order: [TabStatus] = [.waiting, .working, .done, .idle, .exited]
        return order.first(where: statuses.contains) ?? .idle
    }
}

/// The strip above the terminal when the tabs are on the left: the tab's title, and room to
/// drag the window by.
final class TitleStripView: NSView {
    static let height: CGFloat = 40
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { WindowDrag.mouseDown(event, in: window) }

    override func draw(_ dirtyRect: NSRect) {
        let text = TabCardDrawing.text(title, Theme.topicFont, Theme.fg3)
        let width = min(ceil(text.size().width), bounds.width - 24)
        TabCardDrawing.draw(text, x: max(12, (bounds.width - width) / 2), y: (bounds.height - 17) / 2, maxX: bounds.width - 12)
    }

    override var isFlipped: Bool { true }
}
