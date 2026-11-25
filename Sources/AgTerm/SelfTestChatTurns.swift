#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The composer's toolbar: the model and effort menu types the agent's own commands, Send turns
    /// to Stop while the agent works, and the chips follow the agent.
    static func composerCheck(_ chat: ChatPaneView, _ session: TerminalSession, report: (String, Bool, String) -> Void) {
        let composer = chat.composer
        let commands = composer.modelMenu()?.items.compactMap { $0.representedObject as? String } ?? []
        report("model menu offers Claude's models and efforts",
               ["/model opus", "/model sonnet", "/model haiku", "/model", "/effort high", "/effort max"].allSatisfy(commands.contains),
               commands.joined(separator: ", "))
        report("model chip shows model and effort", composer.shownChips.first?.hasPrefix("Opus 5.5") == true, composer.shownChips.first ?? "none")
        report("files chip for an agent that reads @paths", composer.shownChips.contains { $0.contains("Files") }, composer.shownChips.joined(separator: " | "))
        report("empty box: send is off", composer.sendMode == .disabled, "\(composer.sendMode)")
        composer.input.string = "hello"
        composer.textDidChange(Notification(name: NSText.didChangeNotification))
        report("text in the box: send is on", composer.sendMode == .send, "\(composer.sendMode)")
        composer.input.string = ""
        composer.textDidChange(Notification(name: NSText.didChangeNotification))
        var status = composer.status
        status.state = .working(seconds: 3)
        composer.status = status
        report("working with an empty box: stop", composer.sendMode == .stop, "\(composer.sendMode)")
        status.state = .idle
        status.mode = "bypass permissions on"
        composer.status = status
        report("permission mode shows as a chip", composer.shownChips.contains("bypass permissions on"), composer.shownChips.joined(separator: " | "))
        composer.onCommand("/model sonnet")
        after(1.0) {
            print("selftest: chat: model command typed into the terminal:", screenLine(session, containing: "/model sonnet") != nil ? "ok" : "FAIL")
        }
    }

    /// Finished turns fold into a worked line; opening it shows the steps beside a rule, the
    /// changed files open to their diffs, and a turn still going shows every step.
    static func turnCheck(_ controller: MainWindowController, _ window: NSWindow, _ outDir: String,
                          report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        let agy = controller.sessions[4]
        controller.focus(agy.tabID)
        after(0.6) {
            guard let chat = controller.chats[agy.tabID] else {
                report("antigravity chat", false, "")
                return done()
            }
            let rows = chat.transcript.rows
            report("antigravity turns", rows.map(\.kindName) == ["user", "worked", "assistant", "changes", "user", "worked", "assistant"],
                   rows.map(\.kindName).joined(separator: ","))
            if case .worked(_, let steps, let ms)? = rows.dropFirst().first {
                let summary = ChatTurns.summary(steps)
                report("worked line counts the steps", summary == ["thought", "read 2", "edited 1", "ran 2", "1 failed"] && ms == 41_000,
                       "\(summary) \(ms ?? -1)ms")
            }
            let length = chat.transcript.textLength
            if let worked = rows.first(where: { $0.kindName == "worked" }) { chat.transcript.toggle(worked.id) }
            if case .changes(_, let edits)? = rows.first(where: { $0.kindName == "changes" }), let file = edits.first {
                chat.transcript.toggle(ChatTurns.fileID(file))
            }
            report("opening a turn and a file adds them", chat.transcript.textLength > length + 200, "\(length) → \(chat.transcript.textLength)")
            chat.transcript.contentView.scroll(to: .zero)
            chat.transcript.reflectScrolledClipView(chat.transcript.contentView)
            window.displayIfNeeded()
            snapshot(window, "\(outDir)/chat-turn-open-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
            after(0.6) {
                chat.transcript.contentView.scroll(to: .zero)
                chat.transcript.reflectScrolledClipView(chat.transcript.contentView)
                window.displayIfNeeded()
                snapshot(window, "\(outDir)/chat-turn-open-paper.png")
                Preferences.shared.update { $0.themeID = "ink" }
                chat.liveOverride = true
                after(1.0) {
                    let live = chat.transcript.rows.map(\.kindName)
                    report("a live turn shows every step", Array(live.suffix(3)) == ["user", "command", "assistant"], live.joined(separator: ","))
                    chat.transcript.scrollToBottom()
                    window.displayIfNeeded()
                    snapshot(window, "\(outDir)/chat-live-ink.png")
                    chat.liveOverride = nil
                    after(0.8, done)
                }
            }
        }
    }

    /// Antigravity writes a database: a new step shows, and a running step that finishes changes in place.
    static func agyLiveCheck(_ controller: MainWindowController, _ files: [TimelineFeed.Agent: URL],
                             report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        let agy = controller.sessions[4]
        guard let chat = controller.chats[agy.tabID], let file = files[.agy] else { return done() }
        controller.focus(agy.tabID)
        chat.liveOverride = true
        let count = AgyFixture.rows.count
        let lint = AgyFixture.call("c7", "run_command", #"{"CommandLine":"swiftlint","Cwd":"/w/proj"}"#)
        AgyFixture.insert(file, index: count, AgyFixture.user("Run the linter", at: 100))
        AgyFixture.insert(file, index: count + 1, AgyFixture.reply(calls: [lint], at: 101))
        AgyFixture.insert(file, index: count + 2, AgyFixture.run(lint, at: 102, status: 2))
        after(1.5) {
            let running = flat(chat.transcript.rows).last
            report("antigravity: a new running step shows", running.map { if case .command(let c) = $0 { c.status == .running } else { false } } == true,
                   running?.kindName ?? "none")
            AgyFixture.insert(file, index: count + 2, AgyFixture.run(lint, output: "0 violations", exit: 0, at: 102, took: 2))
            AgyFixture.insert(file, index: count + 3, AgyFixture.reply(text: "No lint violations.", at: 105))
            after(1.5) {
                let rows = flat(chat.transcript.rows)
                let finished = rows.contains { if case .commands(_, let list, _) = $0 { list.contains { $0.command == "swiftlint" } } else { false } }
                report("antigravity: the step finishes in place", finished && rows.last == .assistant(id: "agy-\(count + 3)", text: "No lint violations.", streaming: false),
                       rows.suffix(3).map(\.kindName).joined(separator: ","))
                chat.liveOverride = nil
                after(0.6, done)
            }
        }
    }

    /// A transcript rewritten in place (Grok rewrites its history) is read again from the start,
    /// so nothing shows twice.
    static func rewriteCheck(_ outDir: String, report: (String, Bool, String) -> Void) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("chat-fixtures/rewrite.jsonl")
        func user(_ text: String) -> String {
            ChatFixtures.json(["type": "user", "content": [["type": "text", "text": "<user_query>\n\(text)\n</user_query>"]], "prompt_index": 0])
        }
        let target = TranscriptFollower.Target(agent: .grok, cwd: outDir, fixed: url)
        let follower = TranscriptFollower()
        try? (user("first message") + "\n").write(to: url, atomically: false, encoding: .utf8)
        follower.refresh(target)
        // Same start, rewritten: the old offset now falls inside different text.
        try? (user("first message, edited") + "\n" + user("second message") + "\n").write(to: url, atomically: false, encoding: .utf8)
        follower.refresh(target, now: Date().addingTimeInterval(1))
        let texts = follower.entries.compactMap(\.text)
        report("a rewritten transcript is read again", texts == ["first message, edited", "second message"], "\(texts)")
    }
}
#endif
