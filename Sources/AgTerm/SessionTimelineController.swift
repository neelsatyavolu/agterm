import AgTermCore
import AppKit

/// Opens the Session Timeline over a tab and keeps it current while it's open: a second-long
/// timer that reads only what the agent appended, stopped as soon as the panel closes.
final class SessionTimelineController {
    let panel = SessionTimelinePanel()
    private weak var window: NSWindow?
    private(set) weak var session: TerminalSession?
    private var source: SessionTimelineReader.Source?
    /// Oldest first, as the reader returns them.
    private(set) var turns: [SessionTimelineTurn] = []
    private var timer: Timer?
    private var clickMonitor: Any?
    private var note: String?
    /// Views whose clicks toggle the panel themselves, so the outside-click close leaves them alone.
    var toggleButtons: [NSView] = []
    /// Whether the tab is still the one you're looking at; the panel closes when it isn't.
    var isFocused: ((TerminalSession) -> Bool)?

    var isOpen: Bool { panel.superview != nil }

    init() {
        panel.onClose = { [weak self] in self?.close() }
        panel.onSelect = { [weak self] turn in self?.jump(to: turn) }
    }

    /// Opens the timeline at the top right of `session`'s pane.
    func open(_ session: TerminalSession, in window: NSWindow) {
        close(refocus: false)
        guard let content = window.contentView else { return }
        self.window = window
        self.session = session
        source = SessionTimelineReader.source(for: session)
        turns = []
        note = nil
        show()
        panel.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(panel, positioned: .above, relativeTo: nil)
        place()
        window.makeFirstResponder(panel)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isOpen, event.window === self.window else { return event }
            let inside = ([self.panel] + self.toggleButtons).contains { view in
                view.window != nil && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
            if !inside { self.close(refocus: false) }
            return event
        }
    }

    func close(refocus: Bool = true) {
        timer?.invalidate()
        timer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard isOpen else { return }
        panel.removeFromSuperview()
        if refocus, let view = session?.view { window?.makeFirstResponder(view) }
    }

    /// Over the top right corner of the tab's pane.
    private func place() {
        guard let content = panel.superview, let view = session?.view else { return }
        let anchor = content.convert(view.bounds, from: view)
        let height = panel.preferredHeight
        let x = max(8, anchor.maxX - SessionTimelinePanel.width - 8)
        // The content view isn't flipped: the top of the anchor is its maxY.
        let top = content.isFlipped ? anchor.minY + 8 : anchor.maxY - 8
        let y = content.isFlipped ? top : top - height
        panel.frame = NSRect(x: x, y: y, width: SessionTimelinePanel.width, height: height)
    }

    /// Closes when you've moved to another tab; otherwise reads what's new.
    private func tick() {
        guard let session, !session.signals.exited, let window, window.isVisible, isFocused?(session) != false else {
            return close(refocus: false)
        }
        refresh()
    }

    private func refresh() {
        guard let session else { return }
        if session.agentName == nil {
            turns = SessionTimelineShell.commands(SessionTimelineJump.shellRows(session.view.getTerminal()),
                                                  running: session.signals.commandRunning)
            return show()
        }
        if source == nil { source = SessionTimelineReader.source(for: session) }
        guard let source else { return show() }
        SessionTimelineReader.shared.turns(source) { [weak self] turns in
            guard let self, self.isOpen, self.source == source else { return }
            let next = turns ?? []
            guard next != self.turns else { return }
            self.turns = next
            self.show()
        }
    }

    #if DEBUG
    /// Shows sample turns (newest first) in place, for the self-test's snapshots.
    func showForTest(_ turns: [SessionTimelineTurn], empty: String = "") {
        panel.refreshAppearance()
        panel.show(turns, empty: empty)
        place()
    }
    #endif

    private func show() {
        panel.show(turns.reversed(), empty: emptyText, note: note)
        place()
    }

    private var emptyText: String {
        guard let session else { return "" }
        guard let agent = session.agentName else { return "Commands will appear as you run them" }
        if session.isCloud { return "Not available for cloud tabs yet" }
        guard ["claude", "codex", "grok"].contains(agent) else {
            return "Works with Claude Code, Codex and Grok"
        }
        return "Turns will appear as you chat"
    }

    private func jump(to turn: SessionTimelineTurn) {
        guard let session else { return }
        let agent = session.agentName
        SessionTimelineJump.jump(session.view, agent: agent, turn: turn, turns: turns) { [weak self] found in
            guard let self else { return }
            if found {
                self.close()
            } else {
                self.note = "Not in the terminal's scrollback"
                self.show()
                self.note = nil
            }
        }
    }
}
