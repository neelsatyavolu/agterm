import AgTermCore
import AgTermSessionKit
import Foundation

/// Bring Back, the reverse of `CloudMove`: each cloud tab's agent stops at the end of its turn,
/// its repo and the agents' conversations come back from the cloud machine, and a local tab takes
/// its place, resuming the conversation. A repo that changed on this Mac while it was in the cloud
/// (`CloudRepoState`) is left alone: the cloud's changes come back as a patch beside it instead.
/// Main queue, except the copying.
final class CloudBringBack {
    private struct Frozen {
        let tab: TerminalSession
        let resume: String?
        let cwd: String
        let hasAgent: Bool
    }

    private let cloud: CloudHost
    private let isOpen: (TerminalSession) -> Bool
    private let replace: (TerminalSession, TerminalSession) -> Void

    init(cloud: CloudHost, isOpen: @escaping (TerminalSession) -> Bool, replace: @escaping (TerminalSession, TerminalSession) -> Void) {
        self.cloud = cloud
        self.isOpen = isOpen
        self.replace = replace
    }

    /// Brings `tabs` back; an agent mid-turn gets `grace` seconds to finish before it is stopped
    /// and told to continue here.
    func run(_ tabs: [TerminalSession], grace: TimeInterval = 20, done: @escaping (CloudMove.Outcome) -> Void) {
        let tabs = tabs.filter { $0.isCloud && !$0.signals.exited }
        guard !tabs.isEmpty else { return done(.moved(0)) }
        var frozen: [Frozen] = []
        for tab in tabs {
            freeze(tab, grace: grace) { item in
                frozen.append(item)
                if frozen.count == tabs.count { self.copy(frozen, done: done) }
            }
        }
    }

    private func freeze(_ tab: TerminalSession, grace: TimeInterval, then next: @escaping (Frozen) -> Void) {
        tab.pollProcess()
        let cwd = tab.cwd
        let hasAgent = tab.agentName != nil
        let plain = tab.resumeCommand()
        guard let job = tab.foregroundJob else { return next(Frozen(tab: tab, resume: nil, cwd: cwd, hasAgent: false)) }
        let stillThere = { tab.pollProcess(); return tab.foregroundJob == job }
        let busy = { tab.signals.agentBusy == true || tab.status == .working }
        CloudMove.wait(upTo: hasAgent ? grace : 0, until: { !stillThere() || !busy() }) { _ in
            guard stillThere() else { return next(Frozen(tab: tab, resume: plain, cwd: cwd, hasAgent: hasAgent)) }
            let resume = hasAgent ? (busy() ? tab.resumeCommand(prompt: CloudMove.continuePrompt) : nil) ?? plain : nil
            tab.signalForeground(SIGTERM)
            CloudMove.wait(upTo: 6, until: { !stillThere() }) { stopped in
                if !stopped { tab.signalForeground(SIGKILL) }
                CloudMove.wait(upTo: 3, until: { !stillThere() }) { _ in next(Frozen(tab: tab, resume: resume, cwd: cwd, hasAgent: hasAgent)) }
            }
        }
    }

    private func copy(_ frozen: [Frozen], done: @escaping (CloudMove.Outcome) -> Void) {
        let cloud = cloud
        let home = NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = CloudMovePlan.roots(frozen.compactMap { tab in
                let root = (try? cloud.run(["/usr/bin/env", "git", "-C", tab.cwd, "rev-parse", "--show-toplevel"]))
                    .flatMap { $0.status == 0 ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                return CloudMovePlan.folder(cwd: tab.cwd, gitRoot: root, hasAgent: tab.hasAgent, home: home)
            })
            let state = frozen.contains(where: \.hasAgent) ? [home + "/.claude/projects", home + "/.codex/sessions"] : []
            var patches: [(folder: String, patch: String)] = []
            do {
                let changedHere = folders.filter { folder in
                    CloudRepoState.recorded(folder).map { $0.fingerprint != CloudRepoState.current(folder)?.fingerprint } ?? false
                }
                for folder in changedHere {
                    if let patch = try Self.savePatch(for: folder, from: cloud) { patches.append((folder, patch)) }
                }
                try CloudSync.pull(folders: folders.filter { !changedHere.contains($0) }, files: state, from: cloud)
                folders.forEach(CloudRepoState.forget)
            } catch {
                return DispatchQueue.main.async {
                    self.restartThere(frozen)
                    done(.failed("\(error)"))
                }
            }
            DispatchQueue.main.async {
                for (folder, patch) in patches {
                    Notifier.shared.post(title: "Kept this Mac's changes to \((folder as NSString).lastPathComponent)",
                                         body: "It changed here while it was in the cloud, so the cloud's changes are saved in \(patch). "
                                            + "Run git apply on that file to add them.", tabID: "cloud")
                }
                self.reopen(frozen, done: done)
            }
        }
    }

    /// The cloud's changes to `folder` since it moved, saved in its git folder here; nil if the
    /// cloud changed nothing.
    private static func savePatch(for folder: String, from cloud: CloudHost) throws -> String? {
        guard let base = CloudRepoState.recorded(folder)?.base, let gitDir = CloudRepoState.gitDir(folder) else { return nil }
        let patch = try CloudSync.changes(in: folder, since: base, on: cloud)
        guard !patch.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let path = gitDir + "/agterm-cloud-\(stamp).patch"
        try Data(patch.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Local tabs in their places, then a report once their agents run, as `CloudMove` does.
    private func reopen(_ frozen: [Frozen], done: @escaping (CloudMove.Outcome) -> Void) {
        var opened: [(tab: TerminalSession, resumes: Bool)] = []
        for item in frozen where isOpen(item.tab) {
            let saved = item.tab.snapshot()
            let cwd = FileManager.default.fileExists(atPath: item.cwd) ? item.cwd : NSHomeDirectory()
            let local = TerminalSession(cwd: cwd, restoring: SavedTab(cwd: cwd, scrollback: saved.scrollback, resume: item.resume,
                                                                     tabID: saved.tabID, name: saved.name))
            replace(item.tab, local)
            opened.append((local, item.resume != nil))
        }
        let agents = opened.filter(\.resumes).map(\.tab)
        CloudMove.wait(upTo: 30, until: { agents.allSatisfy { $0.pollProcess(); return $0.agentName != nil } }) { started in
            done(started ? .moved(opened.count) : .failed("An agent didn't start again here; check its tab."))
        }
    }

    /// The copy failed: agents start again in the cloud, in their own tabs.
    private func restartThere(_ frozen: [Frozen]) {
        for item in frozen {
            guard let resume = item.resume, isOpen(item.tab), !item.tab.isRunningProgram else { continue }
            item.tab.view.send(txt: "\u{15}" + resume + "\r")
        }
    }
}
