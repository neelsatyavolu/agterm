import AppKit

extension MainWindowController {
    /// View → Session Timeline (⇧⌘L), or the button above the terminal: every prompt sent in the
    /// focused tab; pick one to scroll to it. Pressing it again closes it.
    @objc func toggleSessionTimeline() {
        guard !sessionTimeline.isOpen else { return sessionTimeline.close() }
        guard let session = focusedSession, let window else { return }
        sessionTimeline.open(session, in: window)
    }

    func setUpSessionTimeline() {
        let buttons = [tabBar.timelineButton, titleStrip.timelineButton]
        for button in buttons { button.onClick = { [weak self] in self?.toggleSessionTimeline() } }
        sessionTimeline.toggleButtons = buttons
        sessionTimeline.isFocused = { [weak self] session in self?.focusedSession === session }
    }
}
