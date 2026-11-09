#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Part of `AGTERM_CHAT_CHECK`: the composer's `/` menu in the Claude chat. Types `/`, then
    /// `workf`, moves and completes with ⇥, runs with ⏎, recalls the sent command with ↑, sends picker keys to the agent, and takes
    /// `chat-slash-ink.png` and `chat-slash-paper.png`; then the `@` menu and a pasted image.
    static func slashCheck(_ controller: MainWindowController, _ window: NSWindow, _ outDir: String,
                           report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        let claude = controller.sessions[0]
        controller.focus(claude.tabID)
        guard let chat = controller.chats[claude.tabID] else {
            report("slash menu", false, "no chat")
            return done()
        }
        let composer = chat.composer, input = composer.input
        func press(_ keyCode: UInt16, _ characters: String) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { return }
            input.keyDown(with: event)
        }
        window.makeFirstResponder(input)
        input.string = ""
        input.insertText("/", replacementRange: input.selectedRange())
        after(1.0) {
            report("menu opens on /", composer.menuShown && composer.slashMenu.items.count > SlashMenu.maxRows,
                   "\(composer.slashMenu.items.count) commands")
            input.insertText("workf", replacementRange: input.selectedRange())
            window.displayIfNeeded()
            let names = composer.slashMenu.items.map(\.name)
            report("menu filters", names.first == "workflows" && names.allSatisfy { $0.lowercased().contains("w") },
                   names.prefix(4).joined(separator: ", "))
            snapshot(window, "\(outDir)/chat-slash-ink.png")
            Preferences.shared.update { $0.themeID = "paper" }
            after(0.6) {
                snapshot(window, "\(outDir)/chat-slash-paper.png")
                Preferences.shared.update { $0.themeID = "ink" }
                press(125, "\u{F701}") // ↓
                let second = composer.slashMenu.current?.name ?? ""
                press(48, "\t")
                report("⇥ fills in the command", input.string == "/\(second) " && !composer.menuShown, input.string)
                input.string = ""
                input.insertText("/workf", replacementRange: input.selectedRange())
                press(53, "\u{1b}")
                report("Esc closes the menu, keeps the text", !composer.menuShown && input.string == "/workf", "")
                input.insertText("l", replacementRange: input.selectedRange())
                report("typing reopens it", composer.menuShown, "")
                press(36, "\r")
                report("⏎ runs the highlighted command", input.string.isEmpty, "")
                after(1.2) {
                    report("command typed into the terminal", screenLine(claude, containing: "/workflows") != nil, "")
                    press(126, "\u{F700}") // ↑
                    report("↑ recalls what you sent", input.string == "/workflows", input.string)
                    press(125, "\u{F701}")
                    report("↓ goes back to an empty box", input.string.isEmpty, input.string)
                    // A picker on screen: arrows and ⏎ from the empty box go to the agent.
                    var sent: [String] = []
                    let arrow = composer.onArrow, key = composer.onKey
                    composer.onArrow = { sent.append("\($0)") }
                    composer.onKey = { sent.append($0 == ChatInput.enter ? "enter" : $0) }
                    composer.drivesScreen = true
                    press(125, "\u{F701}")
                    press(36, "\r")
                    composer.drivesScreen = false
                    composer.onArrow = arrow
                    composer.onKey = key
                    report("picker keys go to the agent", sent == ["down", "enter"], sent.joined(separator: ","))
                    report("arrow keys follow cursor mode", ChatInput.arrow(.up, applicationCursor: true) == "\u{1b}OA"
                           && ChatInput.arrow(.up, applicationCursor: false) == "\u{1b}[A", "")
                    mentionCheck(claude, composer, window, outDir, press: press, report: report, done: done)
                }
            }
        }
    }

    /// The `@` menu lists the tab folder's files (the snapshots above are in it) and fills a path
    /// in; a pasted image goes in as `[Image #1]` and reaches the terminal as a pasted path.
    /// Takes `chat-mention-ink.png`.
    private static func mentionCheck(_ claude: TerminalSession, _ composer: ChatComposer, _ window: NSWindow, _ outDir: String,
                                     press: @escaping (UInt16, String) -> Void,
                                     report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        let input = composer.input
        input.string = ""
        input.insertText("look at @chat-slash-i", replacementRange: input.selectedRange())
        after(1.0) {
            let names = composer.slashMenu.items.map(\.name)
            report("@ lists the folder's files", composer.menuShown && names.first == "chat-slash-ink.png", names.prefix(3).joined(separator: ", "))
            window.displayIfNeeded()
            snapshot(window, "\(outDir)/chat-mention-ink.png")
            press(48, "\t")
            report("⇥ fills the path in", input.string == "look at @chat-slash-ink.png " && !composer.menuShown, input.string)
            input.insertText("and @chat-slash-pa", replacementRange: input.selectedRange())
            press(36, "\r")
            report("⏎ on a file fills it in, doesn't send", input.string == "look at @chat-slash-ink.png and @chat-slash-paper.png ", input.string)
            let board = NSPasteboard(name: NSPasteboard.Name("agterm-selftest-\(UUID().uuidString)"))
            board.clearContents()
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                Theme.accent.setFill()
                rect.fill()
                return true
            }
            board.writeObjects([image])
            let attached = composer.attachImages(from: board)
            board.releaseGlobally()
            report("a pasted image goes in as [Image #1]", attached && input.string.hasSuffix("[Image #1] "), input.string)
            press(36, "\r")
            report("sent", input.string.isEmpty, input.string)
            after(1.8) {
                let screen = claude.screenText().replacingOccurrences(of: "\n", with: "")
                report("the image reached the terminal as a path", screen.contains("agterm-chat-images/"), "")
                report("the mentions reached the terminal", screen.contains("look at @chat-slash-ink.png and @chat-slash-paper.png"), "")
                let saved = (try? FileManager.default.contentsOfDirectory(atPath: ChatImages.folder.path)) ?? []
                report("the image was saved as a PNG", saved.contains { $0.hasSuffix(".png") }, "\(saved.count) files")
                done()
            }
        }
    }
}
#endif
