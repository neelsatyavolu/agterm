#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Session Timeline: `AGTERM_SESSIONTIMELINE_CHECK=1 AGTERM_SELFTEST=<dir>`. Runs commands at
    /// zsh's marked prompt, opens the timeline (`session-timeline-shell.png`), jumps to the first
    /// command after pushing it into the scrollback (`session-timeline-jump.png`), finds an
    /// agent-style echoed prompt (`> …`) the way Claude Code tabs are searched, and draws sample
    /// agent turns in both themes (`session-timeline-agent-ink.png`, `-paper.png`). With
    /// `AGTERM_SESSIONTIMELINE_REAL=1` it also reads your newest Claude, Codex and Grok
    /// transcripts and prints what it found.
    static func sessionTimelineCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window, let session = controller.focusedSession else { exit(1) }
        Preferences.shared.update { $0.themeID = "ink" }
        window.setContentSize(NSSize(width: 1000, height: 560))
        controller.showWindow(nil)
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: session timeline: \(name):", ok ? "ok" : "FAIL", detail)
            if !ok { failed = true }
        }
        let timeline = controller.sessionTimeline
        let view = session.view
        after(1.6) { view.send(txt: "clear\r") }
        after(2.2) { view.send(txt: "echo first-command\r") }
        after(2.6) { view.send(txt: "echo second-command\r") }
        after(3.2) { view.send(txt: "printf '> fix the flaky login test\\n  in LoginTests\\n'\r") }
        after(3.8) {
            controller.toggleSessionTimeline()
            report("opens", timeline.isOpen && window.firstResponder === timeline.panel)
        }
        after(5.2) {
            let prompts = timeline.panel.turnsForTest.map(\.prompt)
            report("lists commands newest first", prompts.first?.hasPrefix("printf") == true
                   && Array(prompts.dropFirst()) == ["echo second-command", "echo first-command"], "\(prompts)")
            snapshot(window, "\(outDir)/session-timeline-shell.png")
            timeline.close()
            // Push the first command into the scrollback.
            view.send(txt: "seq 1 120\r")
        }
        after(6.5) {
            let terminal = view.getTerminal()
            let bottom = terminal.buffer.yDisp
            let turns = SessionTimelineShell.commands(SessionTimelineJump.shellRows(terminal), running: false)
            guard let first = turns.first else { report("commands after scrolling", false); return finish() }
            SessionTimelineJump.jump(view, agent: nil, turn: first, turns: turns) { found in
                report("jumps to a command in the scrollback", found && terminal.buffer.yDisp < bottom,
                       "yDisp \(bottom) → \(terminal.buffer.yDisp)")
                report("flashes it", view.subviews.contains { String(describing: type(of: $0)).contains("Flash") })
            }
            after(0.25) {
                snapshot(window, "\(outDir)/session-timeline-jump.png")
                // An agent prompt is found by its text, wrapped over two rows.
                let agentTurn = SessionTimelineTurn(id: "a", prompt: "fix the flaky login test\nin LoginTests", status: .done)
                SessionTimelineJump.jump(view, agent: "claude", turn: agentTurn, turns: [agentTurn]) { found in
                    let shown = (0..<4).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
                    report("finds an echoed agent prompt", found && shown.contains("> fix the flaky login test"), "top \(terminal.buffer.yDisp)")
                }
            }
            after(0.5) {
                snapshot(window, "\(outDir)/session-timeline-jump-agent.png")
                view.scrollTo(row: bottom)
            }
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let sample = [
            SessionTimelineTurn(id: "4", prompt: "Add a test for the redirect after login, then run the whole suite", status: .running, startedAt: now - 20_000),
            SessionTimelineTurn(id: "3", prompt: "Why does the login redirect loop when the session cookie is missing?", status: .done, startedAt: now - 600_000),
            SessionTimelineTurn(id: "2", prompt: "Revert that", status: .cancelled, startedAt: now - 3_900_000),
            SessionTimelineTurn(id: "1", prompt: "Deploy to staging", status: .failed, startedAt: now - 90_000_000),
        ]
        after(8.5) {
            controller.toggleSessionTimeline()
            timeline.showForTest(sample)
        }
        after(8.8) {
            snapshot(window, "\(outDir)/session-timeline-agent-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
            after(0.6) {
                timeline.showForTest(sample)
                snapshot(window, "\(outDir)/session-timeline-agent-paper.png")
                timeline.showForTest([], empty: "Turns will appear as you chat")
                snapshot(window, "\(outDir)/session-timeline-empty-paper.png")
                timeline.close()
                report("closes", !timeline.isOpen)
                // Tabs on the left: the button sits in the strip above the terminal.
                controller.toggleTabsOnLeft()
                after(0.6) {
                    controller.titleStrip.timelineButton.onClick?()
                    report("strip button opens it", timeline.isOpen)
                    timeline.showForTest(sample)
                }
                after(0.9) {
                    snapshot(window, "\(outDir)/session-timeline-sidebar-paper.png")
                    controller.titleStrip.timelineButton.onClick?()
                    report("strip button closes it", !timeline.isOpen)
                    controller.toggleTabsOnLeft()
                    readRealTranscripts(finish)
                }
            }
        }
        func finish() {
            print("selftest: session timeline:", failed ? "FAILED" : "passed")
            exit(failed ? 1 : 0)
        }
    }

    /// Prints the turns of your newest Claude, Codex and Grok conversations, to check the parsers
    /// against real files.
    private static func readRealTranscripts(_ done: @escaping () -> Void) {
        guard ProcessInfo.processInfo.environment["AGTERM_SESSIONTIMELINE_REAL"] == "1" else { return done() }
        let fm = FileManager.default
        func newest(_ files: [URL]) -> URL? {
            files.max { a, b in
                let da = (try? fm.attributesOfItem(atPath: a.path))?[.modificationDate] as? Date ?? .distantPast
                let db = (try? fm.attributesOfItem(atPath: b.path))?[.modificationDate] as? Date ?? .distantPast
                return da < db
            }
        }
        func list(_ dir: URL) -> [URL] { (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var sources: [(String, SessionTimelineReader.Source)] = []
        if let claude = newest(list(home.appendingPathComponent(".claude/projects")).flatMap(list).filter { $0.pathExtension == "jsonl" }) {
            sources.append(("claude", .claude(sessionID: claude.deletingPathExtension().lastPathComponent)))
        }
        let codexDays = list(home.appendingPathComponent(".codex/sessions")).flatMap(list).flatMap(list)
        if let codex = newest(codexDays.flatMap(list).filter { $0.pathExtension == "jsonl" }) { sources.append(("codex", .codex(rollout: codex))) }
        let grokDirs = list(AccountStore.nativeGrokHome.appendingPathComponent("sessions")).flatMap(list)
        if let grok = newest(grokDirs.map { $0.appendingPathComponent("chat_history.jsonl") }.filter { fm.fileExists(atPath: $0.path) }) {
            sources.append(("grok", .grok(sessionID: grok.deletingLastPathComponent().lastPathComponent)))
        }
        var left = sources.count
        if left == 0 { return done() }
        for (name, source) in sources {
            SessionTimelineReader.shared.turns(source) { turns in
                let statuses = Dictionary(grouping: turns ?? [], by: \.status.rawValue).mapValues(\.count)
                print("selftest: session timeline: real \(name):", turns?.count ?? -1, "turns", statuses,
                      "newest:", turns?.last.map { String(SessionTimelineFormat.oneLine($0.prompt).prefix(60)) } ?? "-")
                left -= 1
                if left == 0 { done() }
            }
        }
    }
}
#endif
