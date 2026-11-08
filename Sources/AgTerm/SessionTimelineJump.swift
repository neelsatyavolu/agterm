import AgTermCore
import AppKit
import SwiftTerm

/// Scrolls a terminal to a Session Timeline turn and flashes it, as agmux's `jumpPtyToTurn`.
/// Agents that print to the scrollback (Claude Code, Codex) are found by searching the buffer for
/// the prompt; Grok draws a full-screen view with its own history, so it's driven with its keys.
enum SessionTimelineJump {
    /// Grok: Tab toggles prompt ↔ history focus, `G` goes to the newest turn, Shift+Left back one.
    private static let grokFocusToggle = "\t"
    private static let grokBottom = "G"
    private static let grokPreviousTurn = "\u{1b}[1;2D"

    /// Shows `turn` (one of `turns`, oldest first) in `view`; `done` says whether it was found.
    static func jump(_ view: AgentTerminalView, agent: String?, turn: SessionTimelineTurn, turns: [SessionTimelineTurn],
                     done: @escaping (Bool) -> Void) {
        guard let index = turns.firstIndex(of: turn) else { return done(false) }
        // Repeats of the same prompt after this one, so the right copy is found.
        let repeats = turns[(index + 1)...].filter { $0.prompt == turn.prompt }.count
        let terminal = view.getTerminal()
        if terminal.isCurrentBufferAlternate {
            guard agent == "grok" else { return done(false) }
            return GrokHop(view: view, hops: turns.count - 1 - index + 1, prompt: turn.prompt, done: done).start()
        }
        let rows: Range<Int>?
        if agent == nil {
            // Rows move as old ones scroll off, so find the command again rather than trust its row.
            let same = SessionTimelineShell.commands(shellRows(terminal), running: false).filter { $0.prompt == turn.prompt }
            let match = same.indices.contains(same.count - 1 - repeats) ? same[same.count - 1 - repeats].row : nil
            rows = match.map { $0..<($0 + 1) }
        } else {
            rows = SessionTimelineMatch.promptRows(in: bufferLines(terminal), prompt: turn.prompt,
                                                   occurrenceFromEnd: repeats, codex: agent == "codex")
        }
        guard let rows else { return done(false) }
        view.scrollTo(row: max(0, rows.lowerBound - 2))
        flash(view, row: rows.lowerBound - terminal.buffer.yDisp, height: rows.count)
        done(true)
    }

    /// The normal buffer's rows as text, scrollback first.
    static func bufferLines(_ terminal: Terminal) -> [String] {
        let buffer = terminal.buffer(kind: .normal)
        return (0..<buffer.lineCount).map { buffer.line(at: $0).translateToString(trimRight: true) }
    }

    /// The rows' prompt marks (OSC 133), for the shell commands in a plain tab.
    static func shellRows(_ terminal: Terminal) -> [SessionTimelineShell.Row] {
        let buffer = terminal.buffer(kind: .normal)
        return (0..<buffer.lineCount).map { index in
            let line = buffer.line(at: index)
            var row = SessionTimelineShell.Row(isWrapped: line.isWrapped)
            var input = ""
            for column in 0..<line.count {
                let cell = line[column]
                // Empty cells (and the second half of wide characters) hold no text.
                let empty = cell.getCharacter() == "\u{0}"
                switch cell.semanticContent {
                case .prompt(.initial): row.hasPrompt = true
                case .input where !empty: input.append(terminal.getCharacter(for: cell))
                case .output where !empty: row.hasOutput = true
                default: break
                }
            }
            row.input = input
            return row
        }
    }

    /// A short tint over the rows the turn starts on (`row` counted from the top of the view).
    static func flash(_ view: AgentTerminalView, row: Int, height: Int) {
        let rowCount = view.getTerminal().rows
        // The caret is one cell tall.
        let cell = view.caretFrame.height > 0 ? view.caretFrame.height : view.bounds.height / CGFloat(max(1, rowCount))
        guard row >= 0, row < rowCount else { return }
        let rows = CGFloat(min(height, rowCount - row))
        view.subviews.filter { $0 is SessionTimelineFlash }.forEach { $0.removeFromSuperview() }
        let tint = SessionTimelineFlash(frame: NSRect(x: 0, y: view.bounds.height - CGFloat(row) * cell - rows * cell,
                                                      width: view.bounds.width, height: rows * cell))
        view.addSubview(tint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                tint.animator().alphaValue = 0
            }, completionHandler: { tint.removeFromSuperview() })
        }
    }

    /// Steps Grok's own history back to a turn, reading its screen between keys (agmux
    /// `scrollTuiToNeedle`, hop-count path). Sends nothing unless Grok's footer says where the
    /// keyboard is, since the same keys would otherwise land in your draft.
    private final class GrokHop {
        private let view: AgentTerminalView
        private var hops: Int
        private let prompt: String
        private let done: (Bool) -> Void

        init(view: AgentTerminalView, hops: Int, prompt: String, done: @escaping (Bool) -> Void) {
            self.view = view
            self.hops = min(hops, 400)
            self.prompt = prompt
            self.done = done
        }

        private var screen: [String] {
            let terminal = view.getTerminal()
            return (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        }

        func start() {
            switch SessionTimelineMatch.grokFocus(screen) {
            case .unknown:
                done(false)
            case .scrollback:
                toBottom()
            case .prompt:
                view.send(txt: grokFocusToggle)
                wait(until: { SessionTimelineMatch.grokFocus(self.screen) == .scrollback }) { ok in
                    ok ? self.toBottom() : self.done(false)
                }
            }
        }

        private func toBottom() {
            view.send(txt: grokBottom)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.hop() }
        }

        /// Hop 1 from the bottom selects the newest turn, so turn `n` back takes `n + 1`.
        private func hop() {
            guard hops > 0 else { return finish() }
            hops -= 1
            let before = SessionTimelineMatch.fingerprint(screen)
            view.send(txt: grokPreviousTurn)
            wait(until: { SessionTimelineMatch.fingerprint(self.screen) != before }) { moved in
                // A frame that stops changing is the top of the history.
                moved ? self.hop() : self.finish()
            }
        }

        private func finish() {
            let lines = screen
            if let rows = SessionTimelineMatch.promptRows(in: lines, prompt: prompt) {
                flash(view, row: rows.lowerBound, height: rows.count)
            }
            done(true)
        }

        /// Polls every 25 ms for up to `timeout`, then reports whether `condition` held.
        private func wait(until condition: @escaping () -> Bool, timeout: TimeInterval = 0.15, _ then: @escaping (Bool) -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func poll() {
                if condition() { return then(true) }
                if Date() >= deadline { return then(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
            }
            poll()
        }
    }
}

/// The tint `SessionTimelineJump.flash` lays over a turn; clicks go through to the terminal.
private final class SessionTimelineFlash: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
