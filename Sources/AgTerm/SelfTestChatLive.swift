#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The Chat view with real agents: `AGTERM_CHAT_LIVE_CHECK=claude,codex,grok,agy AGTERM_SELFTEST=<dir>`
    /// (any of them). Each starts in its own tab in `AGTERM_CHAT_LIVE_DIR` (default: the current
    /// folder), switches to Chat once agterm sees the agent, sends a message through the composer
    /// and waits for the reply to show as a chat row; then a second message, so the first turn
    /// folds. Uses each agent's account and a little of its usage.
    static func chatLiveCheck(_ controller: MainWindowController, agents names: String, outDir: String) {
        guard let window = controller.window else { exit(1) }
        let agents = names.split(separator: ",").compactMap { TimelineFeed.Agent(rawValue: String($0)) }
        let dir = ProcessInfo.processInfo.environment["AGTERM_CHAT_LIVE_DIR"] ?? FileManager.default.currentDirectoryPath
        // Codex asks about new hooks before anything else; this run leaves them off rather than trust them.
        let commands: [TimelineFeed.Agent: String] = [.claude: "claude", .codex: "codex --disable hooks", .grok: "grok", .agy: "agy", .agl: "agl"]
        window.setContentSize(NSSize(width: 1180, height: 780))
        controller.showWindow(nil)
        for _ in agents.dropFirst() { controller.newTab() }
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: chat-live: \(name):", ok ? "ok" : "FAIL", detail)
            if !ok { failed = true }
        }
        func run(_ index: Int) {
            guard index < agents.count else { return after(1) { exit(failed ? 1 : 0) } }
            let agent = agents[index], session = controller.sessions[index]
            controller.focus(session.tabID)
            session.view.send(txt: "cd '\(dir)' && \(commands[agent] ?? agent.rawValue)\r")
            wait(60, until: { controller.canChat(session) }) { seen in
                report("\(agent) recognized", seen, session.agentName ?? "no agent")
                guard seen else { return run(index + 1) }
                // Let the agent finish starting (its screen quiet for a few seconds) before typing.
                let start = Date()
                wait(60, until: {
                    Date().timeIntervalSince(start) > 5 && Date().timeIntervalSince(session.signals.lastOutput ?? .distantPast) > 3
                }) { _ in
                    // Codex can open on an update prompt (Esc skips it this once; never Enter, which
                    // updates) or its list of sessions (start a new one).
                    let screen = session.screenText()
                    let key = screen.contains("Update available") ? ChatInput.escape : screen.contains("n new") ? "n" : nil
                    guard let key else { return converse(controller, window, agent, session, outDir, report: report) { run(index + 1) } }
                    session.view.send(txt: key)
                    after(8) {
                        if session.screenText().contains("n new") { session.view.send(txt: "n") }
                        after(6) {
                            converse(controller, window, agent, session, outDir, report: report) { run(index + 1) }
                        }
                    }
                }
            }
        }
        after(1.5) { run(0) }
    }

    private static func converse(_ controller: MainWindowController, _ window: NSWindow, _ agent: TimelineFeed.Agent, _ session: TerminalSession,
                                 _ outDir: String, report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        controller.setChat(true, for: session)
        guard let chat = controller.chats[session.tabID] else {
            report("\(agent) chat opens", false, "")
            return done()
        }
        func replied(_ word: String) -> Bool {
            flat(chat.transcript.rows).contains { if case .assistant(_, let text, _) = $0 { text.lowercased().contains(word) } else { false } }
        }
        chat.composer.input.string = "Reply with just the word pong. Don't use any tools."
        chat.composer.send()
        wait(120, until: { replied("pong") }) { ok in
            report("\(agent) first reply shows", ok, ok ? flat(chat.transcript.rows).map(\.kindName).joined(separator: ",")
                   : "screen: " + session.screenText().split(separator: "\n").suffix(14).joined(separator: " ⏎ "))
            report("\(agent) your message shows", chat.transcript.rows.contains { if case .user(_, let text, _) = $0 { text.contains("pong") } else { false } }, "")
            chat.composer.input.string = "Now run the shell command `echo chat-live` and then reply with just the word done."
            chat.composer.send()
            wait(180, until: { replied("done") && session.status != .working }) { ok in
                let rows = chat.transcript.rows
                report("\(agent) second turn with a command", ok, rows.map(\.kindName).joined(separator: ","))
                report("\(agent) first turn stays a plain exchange", rows.first?.kindName == "user", rows.map(\.kindName).joined(separator: ","))
                report("\(agent) status line or model chip", chat.composer.shownChips.first.map { !$0.isEmpty } ?? false,
                       "\(chat.composer.info.model ?? "no model") · \(chat.composer.info.context?.text ?? "no context")")
                window.displayIfNeeded()
                snapshot(window, "\(outDir)/chat-live-\(agent.rawValue).png")
                done()
            }
        }
    }

    /// Calls `then(true)` once `condition` holds, checking twice a second, or `then(false)` after `seconds`.
    static func wait(_ seconds: Double, until condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func check() {
            if condition() { return then(true) }
            if Date() > deadline { return then(false) }
            after(0.5, check)
        }
        check()
    }
}
#endif

