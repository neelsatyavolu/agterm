import AgTermCore
import AppKit

/// Chat: an agent tab shown as a conversation instead of its terminal. Each pane picks its own
/// view while the tab is open; the agent keeps running in the terminal either way.
extension MainWindowController {
    /// ⌃`: Chat ↔ Terminal for the pane you're typing in.
    @objc func toggleChat() {
        guard let session = focusedSession else { return }
        setChat(chats[session.tabID] == nil, for: session)
    }

    /// Whether agterm can show this tab as a chat: Claude Code, Codex, Grok or agl, with its
    /// transcript on this Mac (not a cloud tab).
    func canChat(_ session: TerminalSession) -> Bool {
        TranscriptFollower.Target(session) != nil
    }

    func setChat(_ on: Bool, for session: TerminalSession, fixture: TranscriptFollower.Target? = nil) {
        if on {
            guard chats[session.tabID] == nil, fixture != nil || canChat(session) else { return }
            let chat = ChatPaneView(session: session, fixture: fixture)
            chat.onModel = { [weak self] in self?.render() }
            chats[session.tabID] = chat
            container.addSubview(chat)
        } else {
            guard let chat = chats.removeValue(forKey: session.tabID) else { return }
            chat.stop()
            chat.removeFromSuperview()
        }
        showSelectedPanes()
        if focusedSession === session { window?.makeFirstResponder(responder(for: session)) }
        render()
    }

    /// What a pane shows: its chat, or its terminal.
    func paneView(for session: TerminalSession) -> NSView {
        chats[session.tabID] ?? session.view
    }

    /// Where typing goes in a pane.
    func responder(for session: TerminalSession) -> NSView {
        chats[session.tabID]?.responder ?? session.view
    }

    /// The tab a first responder inside a chat belongs to.
    func chatTab(containing view: NSView) -> String? {
        var current: NSView? = view
        while let next = current {
            if let chat = next as? ChatPaneView { return chat.tabID }
            current = next.superview
        }
        return nil
    }

    /// An agent that quit (or a tab that closed) drops its pane back to the terminal.
    func dropEndedChats() {
        for (id, chat) in chats {
            guard let session = session(id) else {
                chat.stop()
                chat.removeFromSuperview()
                chats[id] = nil
                continue
            }
            if !canChat(session), !chat.isFixture { setChat(false, for: session) }
        }
    }

    func applyChatAppearance() {
        chats.values.forEach { $0.applyAppearance() }
    }

    /// The title strip's Chat | Term control and, in Chat, the agent's details.
    func updateTitleStrip(_ focused: TerminalSession) {
        let chat = chats[focused.tabID]
        titleStrip.chatMode = chat != nil ? true : canChat(focused) ? false : nil
        titleStrip.onChatMode = { [weak self, weak focused] on in
            guard let self, let focused else { return }
            self.setChat(on, for: focused)
        }
        guard let chat else { return titleStrip.chatInfo = nil }
        if titleStrip.logo == nil { titleStrip.logo = AgentLogo.image(for: chat.agentName) }
        let usage = focused.agentUsage.flatMap { usage in
            [UsageText.tokens(usage.tokens), UsageText.cost(usage.costUSD, incomplete: usage.costIncomplete)].compactMap { $0 }
                .joined(separator: " · ")
        }
        titleStrip.chatInfo = TitleStripView.ChatInfo(
            agent: AgentKind.named(focused.agentName ?? chat.agentName)?.title ?? focused.agentName ?? chat.agentName,
            model: (focused.agentUsage?.model ?? chat.model).flatMap(ModelName.short), folder: focused.folder.isEmpty ? "~" : focused.folder,
            branch: focused.git?.branch, usage: usage?.isEmpty == false ? usage : nil,
            added: focused.agentDiff?.added ?? 0, removed: focused.agentDiff?.removed ?? 0)
    }
}
