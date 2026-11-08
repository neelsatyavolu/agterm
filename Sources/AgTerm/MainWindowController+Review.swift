import AgTermCore
import AppKit

/// What the review tools remember between renders: the panel's width, pull requests already
/// looked up, and the sheet that's open.
final class ReviewState {
    static let panelOpenKey = "diffPanelOpen"
    static let panelWidthKey = "diffPanelWidth"
    /// How long a pull request lookup is trusted before `gh` is asked again.
    static let pullRequestTTL: TimeInterval = 300

    var panelWidth: NSLayoutConstraint?
    var sideToolbar: [NSLayoutConstraint] = []
    var topToolbar: [NSLayoutConstraint] = []
    var pullRequests: [String: (pr: PullRequest?, at: Date)] = [:]
    var lookingUp = Set<String>()
    var sheet: NSWindowController?

    var panelOpen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.panelOpenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.panelOpenKey) }
    }

    var savedWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: Self.panelWidthKey)).nonZero ?? DiffPanelView.defaultWidth }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.panelWidthKey) }
    }
}

private extension CGFloat {
    var nonZero: CGFloat? { self > 0 ? self : nil }
}

extension MainWindowController {
    // MARK: Layout

    /// Puts the changes panel right of the panes and the toolbar in the title bar.
    func installReview(in content: NSView) {
        let width = diffPanel.widthAnchor.constraint(equalToConstant: review.panelOpen ? review.savedWidth : 0)
        review.panelWidth = width
        diffPanel.isHidden = !review.panelOpen
        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: diffPanel.leadingAnchor, constant: -2),
            diffPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            diffPanel.topAnchor.constraint(equalTo: container.topAnchor),
            diffPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            width,
        ])
        review.sideToolbar = [
            reviewToolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            reviewToolbar.centerYAnchor.constraint(equalTo: titleStrip.centerYAnchor),
        ]
        review.topToolbar = [
            reviewToolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            reviewToolbar.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
        ]
        diffPanel.onClose = { [weak self] in self?.toggleChanges() }
        diffPanel.onResize = { [weak self] dx in self?.resizePanel(by: dx) }
        reviewToolbar.changes.onClick = { [weak self] in self?.toggleChanges() }
        reviewToolbar.commit.onClick = { [weak self] in self?.showCommit() }
        reviewToolbar.usage.onClick = { [weak self] in self?.showUsage() }
        reviewToolbar.pullRequest.onClick = { [weak self] in self?.openPullRequest() }
        // Both menus need git or a PATH search first, so they're built after that runs off the main thread.
        reviewToolbar.worktree.onClick = { [weak self] in
            guard let self, let cwd = self.focusedSession?.cwd else { return }
            GitRunner.reads.async { [weak self] in
                let existing = WorktreeActions.list(cwd)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let menu = self.worktreeMenu(existing: existing) else { return }
                    self.reviewToolbar.worktree.popUp(menu)
                }
            }
        }
        reviewToolbar.handOff.onClick = { [weak self] in
            GitRunner.reads.async { [weak self] in
                let installed = Self.installedTargets()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.reviewToolbar.handOff.popUp(self.handOffMenu(installed: installed))
                }
            }
        }
    }

    /// Called from `applyTabPlacement`: beside the title above the terminal, or at the end of the tab bar.
    func placeReviewToolbar() {
        NSLayoutConstraint.deactivate(tabsOnLeft ? review.topToolbar : review.sideToolbar)
        NSLayoutConstraint.activate(tabsOnLeft ? review.sideToolbar : review.topToolbar)
        let room = reviewToolbar.fittingSize.width + 20
        tabBar.trailingReserve = tabsOnLeft ? 0 : room
        titleStrip.trailingReserve = tabsOnLeft ? room : 0
    }

    private func resizePanel(by dx: CGFloat) {
        guard let width = review.panelWidth, let window else { return }
        let limit = max(DiffPanelView.minWidth, window.frame.width * 0.7)
        width.constant = min(limit, max(DiffPanelView.minWidth, width.constant - dx))
        review.savedWidth = width.constant
        focusedSession?.pushSize()
    }

    // MARK: Keeping it current

    /// Called on every render; cheap when nothing changed (the toolbar compares its state, the
    /// panel its fingerprint).
    func updateReview() {
        let session = focusedSession
        var state = ReviewToolbarState()
        state.panelOpen = review.panelOpen
        if let session, !session.isCloud {
            state.isRepo = session.git != nil
            state.changedFiles = session.git?.files ?? 0
            state.ahead = session.git?.ahead ?? 0
            state.unpublished = session.git?.unpublished ?? false
            state.agent = session.agentName
            state.inWorktree = WorktreeNames.isManaged(session.cwd, home: NSHomeDirectory())
            state.pullRequest = pullRequest(for: session)
        }
        let before = reviewToolbar.state.pullRequest
        reviewToolbar.update(state)
        if before != state.pullRequest { placeReviewToolbar() }
        guard review.panelOpen else { return }
        // A cloud tab's files aren't on this Mac.
        diffPanel.show(session.flatMap { $0.isCloud ? nil : diffSource($0) })
    }

    private func diffSource(_ session: TerminalSession) -> DiffSource {
        let git = session.git
        let parts: [String] = [session.cwd, git?.branch ?? "-", "\(git?.files ?? 0)", "\(git?.added ?? 0)", "\(git?.removed ?? 0)",
                               "\(session.agentDiff?.added ?? -1)", "\(session.agentDiff?.removed ?? -1)", session.agentBaseline?.commit ?? "-"]
        return DiffSource(tabID: session.tabID, cwd: session.cwd, baseline: session.agentBaseline,
                          hasAgent: session.agentName != nil, fingerprint: parts.joined(separator: "|"))
    }

    /// The tab branch's pull request as last seen; asks `gh` in the background when that's stale.
    private func pullRequest(for session: TerminalSession) -> PullRequest? {
        // Until the shell's PATH is known, finding gh would wait on it; try again on a later render.
        guard QuickCommandRunner.shared.isReady, GitRunner.ghPath != nil, let branch = session.git?.branch else { return nil }
        let key = session.cwd + "|" + branch
        let cached = review.pullRequests[key]
        if (cached.map { Date().timeIntervalSince($0.at) > ReviewState.pullRequestTTL } ?? true), !review.lookingUp.contains(key) {
            review.lookingUp.insert(key)
            let cwd = session.cwd
            GitRunner.reads.async { [weak self] in
                let pr = GitActions.pullRequest(cwd)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.review.lookingUp.remove(key)
                    self.review.pullRequests[key] = (pr, Date())
                    self.updateReview()
                }
            }
        }
        return cached?.pr
    }

    // MARK: Actions

    @objc func toggleChanges() {
        review.panelOpen.toggle()
        diffPanel.isHidden = !review.panelOpen
        review.panelWidth?.constant = review.panelOpen ? review.savedWidth : 0
        window?.contentView?.layoutSubtreeIfNeeded()
        focusedSession?.pushSize()
        updateReview()
    }

    @objc func showCommit() {
        guard let session = focusedSession, !session.isCloud, session.git != nil, let window, window.attachedSheet == nil else { return NSSound.beep() }
        let cwd = session.cwd
        GitRunner.reads.async { [weak self] in
            let context = GitActions.context(cwd: cwd)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.attachedSheet == nil else { return }
                switch context {
                case let .success(context):
                    let sheet = CommitSheet(context: context)
                    sheet.onDone = { [weak self] _ in
                        guard let self else { return }
                        self.review.pullRequests = self.review.pullRequests.filter { !$0.key.hasPrefix(cwd + "|") }
                        self.refreshGit(cwd)
                        self.updateReview()
                    }
                    self.review.sheet = sheet
                    sheet.begin(for: window)
                case let .failure(failure):
                    self.alert("Can't commit", failure.message)
                }
            }
        }
    }

    @objc func openPullRequest() {
        guard let pr = reviewToolbar.state.pullRequest, let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func showUsage() { UsageWindowController.shared.show() }

    @objc func newWorktreeTab() {
        guard let session = focusedSession, !session.isCloud, session.git != nil, let window, window.attachedSheet == nil else { return NSSound.beep() }
        let cwd = session.cwd, branch = session.git?.branch, agent = session.agentName
        GitRunner.reads.async { [weak self] in
            let installed = Self.installedTargets().map(\.rawValue)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.attachedSheet == nil else { return }
                let sheet = WorktreeSheet(cwd: cwd, currentBranch: branch, currentAgent: agent, installed: installed)
                sheet.onCreate = { [weak self] path, command in
                    self?.addTab(cwd: path, restoring: nil, command: command)
                }
                self.review.sheet = sheet
                sheet.begin(for: window)
            }
        }
    }

    /// Agents that can take over a conversation and are installed. Searches PATH, so call it off the main thread.
    static func installedTargets() -> [HandoffTarget] {
        HandoffTarget.allCases.filter { QuickCommandRunner.shared.executable($0.rawValue) != nil }
    }

    @objc func removeWorktree() {
        guard let session = focusedSession else { return }
        let cwd = session.cwd
        GitRunner.reads.async { [weak self] in
            let removal = WorktreeActions.removal(cwd)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let removal else { return self.alert("Not an agterm worktree", "This tab's folder isn't a worktree agterm made.") }
                self.confirmRemoval(removal)
            }
        }
    }

    private func confirmRemoval(_ removal: WorktreeRemoval) {
        guard let window, window.attachedSheet == nil else { return }
        let tabs = sessions.filter { $0.cwd == removal.path || $0.cwd.hasPrefix(removal.path + "/") }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree \(removal.branch ?? (removal.path as NSString).lastPathComponent)?"
        var lines = ["Deletes \(PathDisplay.folder(removal.path, home: NSHomeDirectory()))."]
        if removal.uncommitted > 0 { lines.append("\(removal.uncommitted) uncommitted change\(removal.uncommitted == 1 ? "" : "s") will be lost.") }
        if let unmerged = removal.unmerged, unmerged > 0, let base = removal.base {
            lines.append("\(unmerged) commit\(unmerged == 1 ? " isn't" : "s aren't") on \(base) yet; they stay on the branch.")
        } else if removal.unmerged == nil, removal.branch != nil {
            lines.append("agterm can't tell whether the branch has commits that aren't merged; it stays.")
        }
        if !tabs.isEmpty { lines.append("\(tabs.count) tab\(tabs.count == 1 ? "" : "s") in it will close.") }
        alert.informativeText = lines.joined(separator: "\n")
        let deleteBranch = NSButton(checkboxWithTitle: "Also delete the branch \(removal.branch ?? "") if it's merged", target: nil, action: nil)
        deleteBranch.state = removal.branchSafeToDelete ? .on : .off
        // Never offer to delete the branch the main checkout works from.
        if removal.branch != nil, removal.branch != removal.base || removal.madeByAgterm { alert.accessoryView = deleteBranch }
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let delete = deleteBranch.state == .on && alert.accessoryView != nil
            GitRunner.writes.async { [weak self] in
                let result = WorktreeActions.remove(removal, deleteBranch: delete)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Tabs close only once their folder is gone (or, with a kept branch, after it).
                    if FileManager.default.fileExists(atPath: removal.path) == false {
                        tabs.filter { self.sessions.contains($0) }.forEach(self.removePane)
                    }
                    if case let .failure(failure) = result { self.alert("Couldn't remove the worktree", failure.message) }
                }
            }
        }
    }

    /// Starts `target` in a new tab with this tab's conversation so far.
    func handOff(_ session: TerminalSession, to target: HandoffTarget) {
        HandoffWriter.prepare(session, to: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(command):
                guard self.sessions.contains(session) else { return }
                self.addTab(cwd: session.cwd, restoring: nil, command: command)
            case let .failure(failure):
                self.alert("Couldn't hand off", failure.message)
            }
        }
    }

    @objc func handOffFromMenu(_ sender: NSMenuItem) {
        guard let session = focusedSession, let id = sender.representedObject as? String, let target = HandoffTarget(rawValue: id) else { return }
        handOff(session, to: target)
    }

    @objc func openWorktreeFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        addTab(cwd: path, restoring: nil)
    }

    // MARK: Menus

    func handOffMenu(installed: [HandoffTarget]) -> NSMenu {
        let menu = NSMenu()
        let current = focusedSession?.agentName
        let header = NSMenuItem(title: "Continue this conversation in", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for target in HandoffTarget.allCases where target.rawValue != current {
            let item = NSMenuItem(title: target.title, action: #selector(handOffFromMenu(_:)), keyEquivalent: "")
            item.representedObject = target.rawValue
            item.target = self
            item.isEnabled = installed.contains(target)
            item.toolTip = item.isEnabled ? "Opens \(target.title) in a new tab with this conversation so far" : "\(target.title) isn't installed"
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    func worktreeMenu(existing: [WorktreeEntry]) -> NSMenu? {
        guard let session = focusedSession else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let add = NSMenuItem(title: "New Worktree Tab…", action: #selector(newWorktreeTab), keyEquivalent: "n")
        add.keyEquivalentModifierMask = [.command, .shift]
        add.target = self
        menu.addItem(add)
        if WorktreeNames.isManaged(session.cwd, home: NSHomeDirectory()) {
            let remove = NSMenuItem(title: "Remove This Worktree…", action: #selector(removeWorktree), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        if !existing.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Open in a New Tab", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in existing {
                let item = NSMenuItem(title: entry.branch ?? (entry.path as NSString).lastPathComponent,
                                      action: #selector(openWorktreeFromMenu(_:)), keyEquivalent: "")
                item.representedObject = entry.path
                item.target = self
                item.state = session.cwd.hasPrefix(entry.path) ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Menu validation for the review items; nil for items that aren't ours.
    func validateReviewItem(_ item: NSMenuItem) -> Bool? {
        let state = reviewToolbar.state
        switch item.action {
        case #selector(toggleChanges):
            item.title = state.panelOpen ? "Hide Changes" : "Show Changes"
            return true
        case #selector(showCommit): return reviewToolbar.commit.isEnabled
        case #selector(openPullRequest): return state.pullRequest != nil
        case #selector(newWorktreeTab): return state.isRepo
        case #selector(removeWorktree): return state.inWorktree
        case #selector(handOffFromMenu(_:)):
            guard let id = item.representedObject as? String else { return false }
            return state.agent != nil && state.agent != id
        case #selector(showUsage): return true
        default: return nil
        }
    }

    private func alert(_ title: String, _ message: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
