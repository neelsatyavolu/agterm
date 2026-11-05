import AgTermCore
import Foundation

/// A hosted session's status as the Mac would show it (`StatusRules`), for the phone while the
/// Mac is off. Fed by the session (output, input, title, bell) and by `observe`, which reads
/// what the pty has in the foreground. Used only on the server's queue.
final class SessionStatus {
    private(set) var signals = StatusSignals()
    private(set) var status: TabStatus = .idle
    /// The agent in the foreground (`AgentCatalog`), and when it started.
    private(set) var agent: String?
    private(set) var agentStartedAt: Date?
    private(set) var foreground: ForegroundInfo?
    private(set) var title = ParsedTitle(topic: "", activity: .unknown)
    private var rawTitle = ""

    func output() { signals.lastOutput = Date() }

    func input(_ bytes: [UInt8]) {
        let now = Date()
        signals.lastInput = now
        if StatusRules.isInterrupt(bytes), agent != nil || status == .working { signals.lastInterrupt = now }
    }

    func bell() { signals.lastBell = Date() }

    func resized() { signals.lastResize = Date() }

    func titleChanged(_ raw: String) {
        guard TitleParser.isNews(raw, previous: rawTitle) else { return }
        rawTitle = raw
        signals.lastTitleChange = Date()
        title = TitleParser.parse(raw)
        signals.titleActivity = title.activity
        signals.titleReportsWaiting = TitleParser.reportsWaiting(raw)
    }

    func exited() { signals.exited = true }

    /// The phone looked at the tab: what finished is no longer news.
    func seen(_ now: Date = Date()) { signals.lastSeen = now }

    /// Takes in the foreground and the screen, then recomputes the status.
    func observe(_ info: ForegroundInfo, screen: String, now: Date = Date()) {
        foreground = info
        let next = info.isShell ? nil : AgentCatalog.agent(argv: info.argv)
        if next != agent {
            agent = next
            agentStartedAt = next == nil ? nil : now
        }
        if info.isShell, !rawTitle.isEmpty {
            // Back at the prompt: a stale spinner or topic mustn't stick.
            rawTitle = ""
            title = ParsedTitle(topic: "", activity: .unknown)
            signals.titleActivity = .unknown
            signals.titleReportsWaiting = false
        }
        signals.commandRunning = !info.isShell && agent == nil
        signals.promptVisible = agent != nil && PermissionPrompt.isVisible(screen.components(separatedBy: "\n"))
        let busy = agent == "claude" && info.claudeSessionID != nil ? info.claudeBusy : nil
        if busy != signals.agentBusy {
            signals.agentBusy = busy
            signals.lastBusyChange = now
        }
        tick(now)
    }

    func tick(_ now: Date = Date()) {
        if StatusRules.isWorking(signals, now: now) { signals.lastWorking = now }
        status = StatusRules.status(signals, now: now)
    }
}
