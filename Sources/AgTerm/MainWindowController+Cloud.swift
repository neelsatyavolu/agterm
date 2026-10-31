import AgTermCore
import AppKit

/// Whether tabs moved to the cloud to be away, and should come home (Settings → Cloud).
enum CloudReturn {
    private static let movedKey = "cloudMovedAway"
    static let automaticKey = "cloudReturnAutomatically"

    /// Set when the tabs moved with the cloud button or on quit; cleared once they are all back.
    static var movedAway: Bool {
        get { UserDefaults.standard.bool(forKey: movedKey) }
        set { UserDefaults.standard.set(newValue, forKey: movedKey) }
    }

    static var automatic: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }
}

/// The controller's part in moving tabs to and from the cloud. Main queue.
final class CloudState {
    var busy = false
    var returning = false
    fileprivate var wakeObserver: NSObjectProtocol?
}

extension MainWindowController {
    /// The cloud button beside +: up while any tab is here, down once they're all in the cloud.
    func updateCloudButton() {
        guard CloudAccount.isEnabled else { return tabBar.cloud = .hidden }
        if cloudState.busy { return tabBar.cloud = .busy }
        let here = sessions.contains { !$0.isCloud && !$0.signals.exited }
        let there = sessions.contains { $0.isCloud && !$0.signals.exited }
        tabBar.cloud = there && !here ? .bringBack : .moveUp
    }

    func tabBarDidRequestCloud(_ bar: TabBarView) {
        guard let cloud = CloudHost.configured else { return SettingsWindowController.shared.show(pane: "Cloud") }
        if bar.cloud == .bringBack {
            return bringBack(sessions.filter(\.isCloud), cloud: cloud, grace: 20)
        }
        let items = CloudMove.preflight(sessions)
        guard !items.isEmpty else { return }
        CloudReturn.movedAway = true
        cloudState.busy = true
        updateCloudButton()
        moveToCloud(items, cloud: cloud) { [weak self] _ in
            self?.cloudState.busy = false
            self?.updateCloudButton()
        }
    }

    /// Right-click → Move to Cloud: just this tab. It stays there until you bring it back.
    @objc func moveTabToCloudFromMenu(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession, !cloudState.busy else { return }
        guard let cloud = CloudHost.configured else { return SettingsWindowController.shared.show(pane: "Cloud") }
        cloudState.busy = true
        updateCloudButton()
        moveToCloud(CloudMove.preflight([session]), cloud: cloud) { [weak self] _ in
            self?.cloudState.busy = false
            self?.updateCloudButton()
        }
    }

    /// Right-click → Bring Back from Cloud: just this tab.
    @objc func bringBackTabFromMenu(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession, !cloudState.busy,
              let cloud = CloudHost.configured else { return }
        bringBack([session], cloud: cloud, grace: 20)
    }

    /// Brings `tabs` home; an agent mid-turn gets `grace` seconds before it is stopped.
    func bringBack(_ tabs: [TerminalSession], cloud: CloudHost, grace: TimeInterval, done: ((CloudMove.Outcome) -> Void)? = nil) {
        cloudState.busy = true
        updateCloudButton()
        window?.subtitle = "Bringing tabs back from the cloud…"
        let back = CloudBringBack(cloud: cloud, isOpen: { [weak self] in self?.sessions.contains($0) == true },
                                  replace: { [weak self] old, new in self?.replaceTab(old, with: new) })
        back.run(tabs, grace: grace) { [weak self] outcome in
            self?.cloudState.busy = false
            self?.window?.subtitle = ""
            self?.updateCloudButton()
            if case .failed(let reason) = outcome {
                Notifier.shared.post(title: "Couldn't bring tabs back from the cloud", body: reason, tabID: "cloud")
            }
            done?(outcome)
            _ = back
        }
    }

    /// After the tabs moved away, they come home at launch and whenever this Mac wakes.
    func startCloudReturn() {
        cloudState.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                                    queue: .main) { [weak self] _ in
            // Give the network a moment to come back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.returnFromCloud() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.returnFromCloud() }
    }

    /// Each cloud tab comes back as soon as its agent isn't in the middle of a turn; tabs still
    /// working are checked again every 15 s. Stops once none are left, or a return fails.
    func returnFromCloud() {
        guard CloudReturn.movedAway, CloudReturn.automatic, !cloudState.returning, let cloud = CloudHost.configured else { return }
        cloudState.returning = true
        func step() {
            let remote = sessions.filter { $0.isCloud && !$0.signals.exited }
            guard !remote.isEmpty else {
                cloudState.returning = false
                CloudReturn.movedAway = false
                return
            }
            let idle = remote.filter { $0.signals.agentBusy != true && $0.status != .working }
            guard !idle.isEmpty, !cloudState.busy else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: step)
            }
            bringBack(idle, cloud: cloud, grace: 0) { [weak self] outcome in
                guard let self else { return }
                // A failed return stops trying until next time, unless nothing is left out there.
                if case .failed = outcome, self.sessions.contains(where: { $0.isCloud && !$0.signals.exited }) {
                    self.cloudState.returning = false
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: step)
            }
        }
        step()
    }
}
