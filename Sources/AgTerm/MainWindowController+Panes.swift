import AgTermCore
import AppKit

/// What's on screen together: one tab, or a split of several, each pane a shell
/// (`TerminalSession`, named by its tab ID), and the one you type in. Every shell is still a tab
/// of its own in the tab bar and sidebar; a split's tabs are highlighted together.
final class PaneGroup {
    var layout: PaneNode
    var focused: String
    /// The empty pane after Split Right or Split Down, waiting for you to choose a tab.
    var picker: String?

    /// As saved: never with the empty pane, which doesn't outlive the window.
    var saved: SavedPaneGroup? {
        guard let layout = picker.map({ layout.removing($0) }) ?? layout else { return nil }
        return SavedPaneGroup(layout: layout, focused: layout.contains(focused) ? focused : layout.panes[0])
    }

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

    /// ⌘D: an empty pane beside the one you're typing in, to show another tab or a new shell.
    @objc func splitRight() { split(.columns) }
    /// ⇧⌘D: the same, below it.
    @objc func splitDown() { split(.rows) }
    /// Shell → Unsplit: every pane of the split back to a tab of its own.
    @objc func unsplitTab() { unsplit() }

    @objc func splitRightFromMenu(_ sender: NSMenuItem) { splitFromMenu(sender, .columns) }
    @objc func splitDownFromMenu(_ sender: NSMenuItem) { splitFromMenu(sender, .rows) }

    private func splitFromMenu(_ sender: NSMenuItem, _ axis: PaneAxis) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        focus(session.tabID)
        split(axis)
    }

    /// Right-clicking a tab that isn't on screen: show it beside the one that is.
    @objc func showRightFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession).map { show($0, beside: .columns) }
    }

    @objc func showBelowFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession).map { show($0, beside: .rows) }
    }

    @objc func moveToOwnTabFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession).map(moveToOwnTab)
    }

    @objc func unsplitFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession).map { unsplit($0) }
    }

    /// The empty pane's list: a new shell, then every tab not already on screen.
    func pickerChoices(for group: PaneGroup) -> [PanePickerView.Choice] {
        let folder = group.layout.panes.compactMap(session(_:)).first?.folder ?? ""
        return [PanePickerView.Choice(tabID: nil, title: "New Shell", detail: folder.isEmpty ? "~" : folder)]
            + sessions.filter { !group.layout.contains($0.tabID) }.map { tab in
                PanePickerView.Choice(tabID: tab.tabID, title: tab.topic,
                                      detail: [tab.agentName.map { AgentKind.named($0)?.title ?? $0 }, tab.folder.isEmpty ? "~" : tab.folder]
                                          .compactMap { $0 }.joined(separator: " · "),
                                      logo: tab.agentName.flatMap(AgentLogo.image(for:)))
            }
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
                guard let self, let view = window.firstResponder as? NSView, let group = self.selectedGroup,
                      let tabID = (view as? AgentTerminalView).flatMap({ view in self.sessions.first { $0.view === view }?.tabID })
                          ?? self.chatTab(containing: view),
                      group.layout.contains(tabID), group.focused != tabID else { return }
                self.focus(tabID)
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
        placeReviewToolbar()
        window?.contentView?.layoutSubtreeIfNeeded()
        focusedSession?.pushSize()
    }

    func setCloudButton(_ cloud: TabBarView.Cloud) {
        tabBar.cloud = cloud
        sidebar.cloud = cloud
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let answer = validateReviewItem(item) { return answer }
        switch item.action {
        case #selector(toggleTabsOnLeft):
            item.state = tabsOnLeft ? .on : .off
            return true
        case #selector(selectPaneLeft), #selector(selectPaneRight), #selector(selectPaneAbove), #selector(selectPaneBelow),
             #selector(nextPane), #selector(previousPane), #selector(unsplitTab):
            return (selectedGroup?.layout.panes.count ?? 0) > 1
        case #selector(splitRight), #selector(splitDown):
            return focusedSession != nil
        case #selector(toggleChat):
            let chat = focusedSession.map { chats[$0.tabID] != nil } ?? false
            item.state = chat ? .on : .off
            return chat || focusedSession.map(canChat) == true
        default:
            return true
        }
    }

    // MARK: Building the cards

    /// What a tab's card shows. `selected`: on screen (every tab of the shown split);
    /// `focused`: the one you type in.
    func tabModel(_ s: TerminalSession) -> TabModel {
        let moving = cloudState.moving[ObjectIdentifier(s)]
        let shown = selectedGroup?.layout.contains(s.tabID) == true
        var model = TabModel(topic: s.topic, folder: s.folder, git: s.git,
                             agentDiff: s.agentDiff.map { DiffCount(added: $0.added, removed: $0.removed) },
                             status: s.status, selected: shown, inCloud: s.isCloud,
                             moving: moving?.label, movingProgress: moving?.progress)
        model.focused = shown && selectedGroup?.focused == s.tabID
        model.agent = s.agentName.map { AgentKind.named($0)?.title ?? $0 }
        model.model = s.agentUsage?.model.flatMap(ModelName.short)
        model.usage = s.agentUsage.flatMap { usage in
            let parts = [UsageText.cost(usage.costUSD, incomplete: usage.costIncomplete), UsageText.tokens(usage.tokens)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        model.agentSince = s.agentRunningSince
        model.program = s.agentName == nil && s.foregroundName != s.shellName ? s.foregroundName : nil
        model.logo = s.agentName.flatMap(AgentLogo.image(for:))
        model.pinned = s.pinned
        model.browserTabs = PerchLink.shared.tabs[s.tabID] ?? 0
        return model
    }
}
