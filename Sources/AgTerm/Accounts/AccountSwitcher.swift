import AgTermCore
import Foundation

/// Moves an agent to another login the moment it stops at a usage limit:
/// 1. Its own transcript says so (Claude Code's 429 record, Codex's limit event), seen within a second.
/// 2. The other logins are checked, and the one with the most left is picked.
/// 3. The agent is stopped and the same conversation resumed on that login, in the same tab,
///    with "continue" as its first message, so the turn that hit the limit finishes.
final class AccountSwitcher {
    static let shared = AccountSwitcher()
    static let continuePrompt = "Continue where you left off."
    /// At most this many switches per tab in `window`, so two empty logins can't ping-pong.
    static let maxSwitches = 3
    static let window: TimeInterval = 30 * 60
    /// Transcript read back when a tab is first followed, so a limit hit just before then counts.
    static let backlog: UInt64 = 512 * 1024

    private let queue = DispatchQueue(label: "agterm.account-switcher", qos: .utility)
    private var tails: [String: TranscriptTail] = [:]
    private var lookedUp: [String: String] = [:]
    private var busy: Set<String> = []
    private var history: [String: [Date]] = [:]
    /// Newest limit already handled per tab, so a rewritten transcript can't replay it.
    private var handled: [String: Date] = [:]

    /// The agent a switch is acting on, captured when the limit was seen.
    private struct Target {
        let provider: AccountProvider
        let group: pid_t
        let sessionID: String
        let launch: TabLaunch
    }

    /// Called every second with the open tabs.
    func poll(_ sessions: [TerminalSession]) {
        let open = Set(sessions.map(\.tabID))
        for key in Set(tails.keys).union(history.keys).union(handled.keys).union(busy) where !open.contains(key) {
            tails[key] = nil; lookedUp[key] = nil; history[key] = nil; handled[key] = nil; busy.remove(key)
        }
        for session in sessions {
            guard let provider = session.agentName.flatMap(AccountProvider.init(rawValue:)), !busy.contains(session.tabID),
                  let started = session.agentStartedAt, let tail = tail(for: session, provider) else { continue }
            let tabID = session.tabID
            let since = max(started.addingTimeInterval(-5), handled[tabID] ?? .distantPast)
            queue.async {
                let hit = tail.newLines().lazy.compactMap { line, backlog -> LimitHit? in
                    guard let hit = provider == .claude ? LimitDetector.claude(line: line.text) : LimitDetector.codex(line: line.text) else { return nil }
                    // Only limits from this run of the agent; undated lines only if they're new.
                    if let time = hit.timestamp { return time > since ? hit : nil }
                    return backlog ? nil : hit
                }.first
                guard let hit else { return }
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session, session.tabID == tabID else { return }
                    self.handled[tabID] = hit.timestamp ?? Date()
                    self.limitReached(session, provider, hit, transcript: tail.url)
                }
            }
        }
    }

    /// The transcript this tab's agent is writing. Finding it scans folders, so only look again
    /// when the agent changes.
    private func tail(for session: TerminalSession, _ provider: AccountProvider) -> TranscriptTail? {
        let key = provider.rawValue + ":" + (session.claudeSessionID ?? "") + ":" + String(session.foregroundGroup ?? 0)
        if let tail = tails[session.tabID], lookedUp[session.tabID] == key { return tail }
        let url: URL?
        switch provider {
        case .claude:
            url = session.claudeSessionID.flatMap(TranscriptDiff.claudeTranscript)
        case .codex:
            // A running Codex holds its rollout open: exactly this tab's conversation, even with
            // other Codex tabs in the same folder or an older conversation resumed.
            url = session.foregroundGroup.flatMap { group in
                ProcInfo.openFiles(group: group) { $0.contains("/sessions/") && $0.hasSuffix(".jsonl") && $0.contains("rollout-") }.first
            }.map(URL.init(fileURLWithPath:))
        }
        guard let url else { return nil }
        lookedUp[session.tabID] = key
        if let tail = tails[session.tabID], tail.url == url { return tail }
        let tail = TranscriptTail(url: url, backlog: Self.backlog)
        tails[session.tabID] = tail
        return tail
    }

    // MARK: Switching

    private func limitReached(_ session: TerminalSession, _ provider: AccountProvider, _ hit: LimitHit, transcript: URL) {
        let store = AccountStore.shared
        // Only agents agterm started on a login it manages, recorded for this very run.
        guard let launch = AccountStore.launch(tabID: session.tabID, provider: provider),
              launch.account != AccountStore.external,
              let started = session.agentStartedAt, abs(launch.startedAt.timeIntervalSince(started)) < 20,
              let group = session.foregroundGroup else { return }
        let monitor = UsageMonitor.shared
        monitor.markExhausted(provider, launch.account)
        guard store.settings.autoSwitch, !store.accounts(provider).isEmpty else { return }
        let sessionID: String?
        switch provider {
        case .claude: sessionID = transcript.deletingPathExtension().lastPathComponent
        case .codex: sessionID = Self.firstLine(transcript).flatMap(AgentResume.codexSessionID)
        }
        guard let sessionID, !sessionID.isEmpty else {
            return notify(session, "Couldn't switch \(provider.title)", "agterm couldn't tell which conversation to resume.")
        }
        let now = Date()
        let recent = (history[session.tabID] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.maxSwitches else {
            return notify(session, "\(provider.title) is out of usage", "Stopped switching accounts in this tab after \(Self.maxSwitches) tries in 30 minutes. \(hit.message)")
        }
        let target = Target(provider: provider, group: group, sessionID: sessionID, launch: launch)
        busy.insert(session.tabID)
        // Fresh readings for every login, the one that just ran out included (for its reset time).
        monitor.refresh(provider, monitor.ids(provider, enabledOnly: true)) { [weak self, weak session] in
            guard let self, let session else { return }
            monitor.markExhausted(provider, launch.account)
            guard let next = AccountPicker.next(monitor.candidates(provider), excluding: [launch.account], now: Date()) else {
                self.busy.remove(session.tabID)
                return self.notify(session, "Every \(provider.title) account is out of usage", hit.message)
            }
            self.history[session.tabID] = recent + [Date()]
            self.switchTab(session, target, to: next)
        }
    }

    private func switchTab(_ session: TerminalSession, _ target: Target, to next: String) {
        let provider = target.provider
        let prompt = AccountStore.shared.settings.continueAfterSwitch ? Self.continuePrompt : nil
        let resume: String?
        switch provider {
        case .claude: resume = AgentResume.commandLine(argv: ["claude"] + target.launch.args, claudeSessionID: target.sessionID, prompt: prompt)
        case .codex: resume = AgentResume.codexCommandLine(userArgs: target.launch.args, sessionID: target.sessionID, prompt: prompt)
        }
        guard let resume else {
            busy.remove(session.tabID)
            return notify(session, "Couldn't switch \(provider.title)", "This kind of \(provider.title) run can't be resumed.")
        }
        // Naming the login on the command itself means nothing can change it before it starts.
        let command = "AGTERM_ACCOUNT=\(ShellEscape.path(next)) " + resume
        let label = AccountStore.shared.label(next, provider: provider)
        let stillThere = { session.foregroundGroup == target.group }
        let cancel: () -> Void = { [weak self] in _ = self?.busy.remove(session.tabID) }

        // The limit ends the turn; give the agent a moment to settle at its prompt first.
        wait(upTo: 20, until: { !stillThere() || (session.signals.agentBusy != true && session.status != .working) }) { [weak self] _ in
            // You closed it or started something else meanwhile: leave the tab alone.
            guard stillThere() else { return cancel() }
            session.signalForeground(SIGTERM)
            self?.wait(upTo: 6, until: { !session.isRunningProgram }) { stopped in
                if !stopped, stillThere() { session.signalForeground(SIGKILL) }
                self?.wait(upTo: 3, until: { !session.isRunningProgram }) { atPrompt in
                    // Only ever type into the shell.
                    guard atPrompt else {
                        cancel()
                        return self?.notify(session, "Couldn't switch \(provider.title)", "\(provider.title) didn't stop, so agterm left the tab as it was.") ?? ()
                    }
                    session.view.send(txt: "\u{15}" + command + "\r")
                    self?.confirm(session, provider, label: label, continued: prompt != nil)
                }
            }
        }
    }

    /// Reports the switch once the agent is running again.
    private func confirm(_ session: TerminalSession, _ provider: AccountProvider, label: String, continued: Bool) {
        wait(upTo: 30, until: { session.agentName == provider.rawValue }) { [weak self] started in
            guard let self else { return }
            self.busy.remove(session.tabID)
            guard started else {
                return self.notify(session, "Switched \(provider.title) to \(label)", "The conversation didn't start again on its own; check the tab.")
            }
            self.notify(session, "Switched \(provider.title) to \(label)", continued
                ? "The last account ran out of usage. Continuing the same conversation."
                : "The last account ran out of usage. The conversation is ready to continue.")
        }
    }

    private func notify(_ session: TerminalSession, _ title: String, _ body: String) {
        Notifier.shared.post(title: title, body: body, tabID: session.tabID)
    }

    /// Checks `condition` every 0.25 s on the main queue; `done(true)` once it holds, `done(false)` at the deadline.
    private func wait(upTo seconds: TimeInterval, until condition: @escaping () -> Bool, then done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func check() {
            if condition() { return done(true) }
            if Date() >= deadline { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
        }
        check()
    }

    private static func firstLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}

/// Reads lines appended to a file since the last call. The first call also returns up to
/// `backlog` bytes from before, marked as such.
final class TranscriptTail {
    struct Line { let text: String }

    let url: URL
    private var offset: UInt64
    private var backlogEnd: UInt64
    private var partial = Data()

    init(url: URL, backlog: UInt64) {
        self.url = url
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        offset = size > backlog ? size - backlog : 0
        backlogEnd = size
    }

    func newLines() -> [(Line, Bool)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? offset
        if size < offset {
            // Rewritten from the start: everything in it now counts as old.
            offset = 0
            backlogEnd = size
            partial = Data()
        }
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let start = offset
        let data = (try? handle.read(upToCount: Int(min(size - offset, 64 * 1024 * 1024)))) ?? Data()
        offset += UInt64(data.count)
        let carried = UInt64(partial.count)
        partial.append(data)
        guard let last = partial.lastIndex(of: 0x0A) else { return [] }
        var lines: [(Line, Bool)] = []
        var position = start - carried
        for piece in partial[...last].split(separator: 0x0A, omittingEmptySubsequences: false) {
            lines.append((Line(text: String(decoding: piece, as: UTF8.self)), position < backlogEnd))
            position += UInt64(piece.count) + 1
        }
        partial = Data(partial[partial.index(after: last)...])
        return lines.filter { !$0.0.text.isEmpty }
    }
}
