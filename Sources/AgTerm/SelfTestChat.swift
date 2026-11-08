#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Chat view: `AGTERM_CHAT_CHECK=1 AGTERM_SELFTEST=<dir>`. Opens three tabs as Claude Code,
    /// Codex and Grok chats fed from fixture transcripts written to `<dir>/chat-fixtures`, takes
    /// `chat-<agent>-ink.png` and `-paper.png`, then checks streaming appends, a half-written last
    /// line, the approval card, the composer typing into the terminal, ⌃` and back, split panes
    /// each with their own view, and a 12,000-row transcript opening in time.
    static func chatCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        let wasLeft = controller.tabsOnLeft
        let theme = Preferences.shared.appearance.themeID
        UserDefaults.standard.set(true, forKey: MainWindowController.tabsOnLeftKey)
        controller.applyTabPlacement()
        window.setContentSize(NSSize(width: 1180, height: 780))
        controller.newTab()
        controller.newTab()
        controller.showWindow(nil)
        // The first shots are named "ink": start in Ink whatever the saved theme is.
        Preferences.shared.update { $0.themeID = "ink" }
        let dir = (outDir as NSString).appendingPathComponent("chat-fixtures")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = ChatFixtures.write(to: dir)
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: chat: \(name):", ok ? "ok" : "FAIL", detail)
            if !ok { failed = true }
        }
        func finish() {
            Preferences.shared.update { $0.themeID = theme }
            UserDefaults.standard.set(wasLeft, forKey: MainWindowController.tabsOnLeftKey)
            after(0.5) { exit(failed ? 1 : 0) }
        }

        after(1.0) {
            let agents: [TimelineFeed.Agent] = [.claude, .codex, .grok]
            for (index, agent) in agents.enumerated() {
                let session = controller.sessions[index]
                controller.focus(session.tabID)
                controller.setChat(true, for: session, fixture: .init(agent: agent, cwd: dir, fixed: files[agent]))
            }
            after(1.5) {
                for (index, agent) in agents.enumerated() {
                    let session = controller.sessions[index]
                    guard let chat = controller.chats[session.tabID] else { report("\(agent) chat open", false); continue }
                    let kinds = Set(chat.transcript.rows.map(\.kindName))
                    report("\(agent) rows", kinds.isSuperset(of: ChatFixtures.expectedKinds[agent]!),
                           chat.transcript.rows.map(\.kindName).joined(separator: ","))
                }
                let claude = controller.sessions[0]
                controller.focus(claude.tabID)
                report("terminal hidden under chat", claude.view.isHidden && controller.chats[claude.tabID]?.isHidden == false)
                report("composer has focus", window.firstResponder === controller.chats[claude.tabID]?.responder)
                report("title strip shows Chat control", controller.titleStrip.chatMode == true && controller.titleStrip.chatInfo != nil)
                report("title strip shows the model", controller.titleStrip.chatInfo?.model == "Opus 5.5"
                       && controller.titleStrip.logo != nil, controller.titleStrip.chatInfo?.model ?? "none")
                snapshots(controller, window, outDir, "ink") {
                    Preferences.shared.update { $0.themeID = "paper" }
                    after(0.6) {
                        snapshots(controller, window, outDir, "paper") {
                            Preferences.shared.update { $0.themeID = "ink" }
                            liveChecks(controller, window, outDir, files, report: report, done: finish)
                        }
                    }
                }
            }
        }
    }

    private static func snapshots(_ controller: MainWindowController, _ window: NSWindow, _ outDir: String, _ theme: String,
                                  done: @escaping () -> Void) {
        let names = ["claude", "codex", "grok"]
        func shoot(_ index: Int) {
            guard index < names.count else { return done() }
            controller.focus(controller.sessions[index].tabID)
            after(0.4) {
                snapshot(window, "\(outDir)/chat-\(names[index])-\(theme).png")
                shoot(index + 1)
            }
        }
        shoot(0)
    }

    private static func liveChecks(_ controller: MainWindowController, _ window: NSWindow, _ outDir: String,
                                   _ files: [TimelineFeed.Agent: URL], report: @escaping (String, Bool, String) -> Void,
                                   done: @escaping () -> Void) {
        let claude = controller.sessions[0]
        controller.focus(claude.tabID)
        guard let chat = controller.chats[claude.tabID], let file = files[.claude] else { return done() }
        let before = chat.transcript.rows.count
        let first = chat.transcript.first
        let length = chat.transcript.textLength
        ChatFixtures.append(file, ChatFixtures.claudeReply("s1", "Streamed in after the chat opened."))
        ChatFixtures.append(file, "{\"type\":\"assistant\",\"uuid\":\"half", newline: false)
        after(1.2) {
            report("appended reply shows", chat.transcript.rows.count == before + 1, "\(before) → \(chat.transcript.rows.count)")
            report("half-written line waits", chat.transcript.rows.count == before + 1, "")
            report("update kept the loaded rows", chat.transcript.first == first, "")
            // The new reply lands before the queued message, so only the last row or two are redone.
            let replaced = chat.transcript.lastReplaced
            report("only the tail re-laid out", replaced.location > length * 3 / 4 && replaced.location < length,
                   "replaced \(replaced.location)..<\(length) of \(length)")
            ChatFixtures.append(file, "\",\"timestamp\":\"2026-11-08T12:10:00Z\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Finished the line.\"}]}}")
            claude.view.send(txt: "clear; printf ' Bash command\\n\\n   swift build\\n   Build the project\\n\\n Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n\\n Esc to cancel\\n'\r")
            after(1.5) {
                report("finished line shows", chat.transcript.rows.count == before + 2, "")
                report("approval card from the screen", chat.card.isApproval && !chat.card.isHidden, "")
                snapshot(window, "\(outDir)/chat-approval-ink.png")
                chat.card.show(.screen(["Select model", "❯ Default (recommended)", "  Opus 5.5", "  Sonnet 5", "Enter to confirm · Esc to exit"]))
                window.displayIfNeeded()
                snapshot(window, "\(outDir)/chat-screen-card-ink.png")
                chat.composer.input.string = "echo chat-typed-\("ok")"
                chat.composer.send()
                after(1.2) {
                    report("composer typed into the terminal", screenLine(claude, containing: "chat-typed-ok") != nil, "")
                    controller.toggleChat()
                    report("⌃` shows the terminal", controller.chats[claude.tabID] == nil && !claude.view.isHidden
                           && window.firstResponder === claude.view, "")
                    // A real agent tab comes back with ⌃`; the fixture tab has no agent, so it's reopened directly.
                    controller.setChat(true, for: claude, fixture: .init(agent: .claude, cwd: outDir, fixed: file))
                    report("chat shows again", controller.chats[claude.tabID] != nil, "")
                    otherPrompts(controller, window, outDir, report: report) {
                    splitCheck(controller, window, outDir, report: report) {
                        largeCheck(controller, outDir, report: report)
                        done()
                    }
                    }
                }
            }
        }
    }

    /// Codex's approval prompt as a card, and Grok's (which agterm can't parse) as the screen card, in Paper.
    private static func otherPrompts(_ controller: MainWindowController, _ window: NSWindow, _ outDir: String,
                                     report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        let codex = controller.sessions[1], grok = controller.sessions[2]
        Preferences.shared.update { $0.themeID = "paper" }
        controller.focus(codex.tabID)
        codex.view.send(txt: "clear; printf '  Would you like to run the following command?\\n\\n  $ npm test\\n\\n› 1. Yes, proceed (y)\\n"
                        + "  2. Yes, and do not ask again for this command (a)\\n  3. No, and tell Codex what to do differently (esc)\\n\\n"
                        + "  Press enter to confirm or esc to cancel\\n'\r")
        after(1.5) {
            let chat = controller.chats[codex.tabID]
            report("codex approval card", chat?.card.isApproval == true && chat?.card.isHidden == false, "")
            snapshot(window, "\(outDir)/chat-approval-codex-paper.png")
            controller.focus(grok.tabID)
            after(0.5) {
                let lines = ["Choose a model", "› grok-4.7-build-fast", "  grok-4.7-reasoning", "↑↓ to move · enter to select"]
                controller.chats[grok.tabID]?.card.show(.screen(ChatRows.screenExcerpt(lines)))
                window.displayIfNeeded()
                snapshot(window, "\(outDir)/chat-screen-card-grok-paper.png")
                report("grok screen card", controller.chats[grok.tabID]?.card.isHidden == false, "")
                Preferences.shared.update { $0.themeID = "ink" }
                controller.focus(controller.sessions[0].tabID)
                after(0.5, done)
            }
        }
    }

    /// A chat pane beside a terminal pane: each keeps its own view.
    private static func splitCheck(_ controller: MainWindowController, _ window: NSWindow, _ outDir: String,
                                   report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        let claude = controller.sessions[0]
        controller.focus(claude.tabID)
        controller.splitRight()
        controller.fillPicker(with: nil)
        after(1.0) {
            guard let shell = controller.focusedSession, shell !== claude, let chat = controller.chats[claude.tabID] else {
                report("split", false, "")
                return done()
            }
            report("split keeps the chat pane", !chat.isHidden && chat.frame.maxX < shell.view.frame.minX && !shell.view.isHidden, "")
            report("terminal under the chat takes its size", claude.view.frame.size == chat.frame.size, "")
            report("new pane has no chat", controller.chats[shell.tabID] == nil && controller.titleStrip.chatMode == nil, "")
            window.setContentSize(NSSize(width: 980, height: 700))
            after(0.5) {
                report("resize follows", claude.view.frame.size == chat.frame.size, "")
                snapshot(window, "\(outDir)/chat-split-ink.png")
                done()
            }
        }
    }

    /// 12,000 rows: read, build and lay out the newest window, timed.
    private static func largeCheck(_ controller: MainWindowController, _ outDir: String, report: (String, Bool, String) -> Void) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("chat-fixtures/large.jsonl")
        ChatFixtures.writeLarge(url, turns: 4_000)
        let start = Date()
        let follower = TranscriptFollower()
        follower.refresh(.init(agent: .claude, cwd: outDir, fixed: url))
        let read = Date()
        let rows = ChatRows.build(follower.entries, working: false)
        let built = Date()
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.update(rows)
        let shown = Date()
        let elapsed = shown.timeIntervalSince(start)
        // Debug builds run the parser several times slower than release; the view's part is what this pins.
        report("12k-row transcript opens", rows.count >= 12_000 && shown.timeIntervalSince(built) < 0.3
               && view.first == rows.count - ChatTranscriptView.window,
               String(format: "%d rows: read %.0f ms, rows %.0f ms, view %.0f ms, total %.0f ms", rows.count,
                      read.timeIntervalSince(start) * 1000, built.timeIntervalSince(read) * 1000, shown.timeIntervalSince(built) * 1000, elapsed * 1000))
    }
}
#endif
