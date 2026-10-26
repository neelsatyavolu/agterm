import AgTermCore
import AppKit
import SwiftUI

extension Notification.Name {
    /// The new-agent-tab shortcut changed in Settings.
    static let agtermShortcutChanged = Notification.Name("agterm.shortcutChanged")
}

extension AgentIntegration {
    static let newAgentTabShortcutKey = "newAgentTabShortcut"

    /// Shell → New Agent Tab's shortcut, ⌥⌘T unless you changed it.
    static var newAgentTabShortcut: KeyShortcut {
        get { KeyShortcut.load(key: newAgentTabShortcutKey, fallback: .newAgentTabDefault) }
        set {
            newValue.save(key: newAgentTabShortcutKey)
            NotificationCenter.default.post(name: .agtermShortcutChanged, object: nil)
        }
    }
}

extension KeyShortcut {
    init?(_ event: NSEvent) {
        guard let key = event.characters(byApplyingModifiers: []) else { return nil }
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(key: key, modifiers: modifiers)
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// The title of another menu item that already answers to this shortcut, if any.
    func conflict(in menu: NSMenu?, ignoring action: Selector) -> String? {
        for item in menu?.items ?? [] {
            if let title = conflict(in: item.submenu, ignoring: action) { return title }
            guard item.action != action, !item.keyEquivalent.isEmpty else { continue }
            var flags = item.keyEquivalentModifierMask.intersection([.control, .option, .shift, .command])
            // An uppercase key equivalent means shift, even when the mask leaves it out.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { flags.insert(.shift) }
            if item.keyEquivalent.lowercased() == key, flags == eventFlags { return item.title }
        }
        return nil
    }
}

extension NSMenuItem {
    func setShortcut(_ shortcut: KeyShortcut) {
        keyEquivalent = shortcut.key
        keyEquivalentModifierMask = shortcut.eventFlags
    }
}

/// Click, then press the new shortcut; esc cancels. Refuses shortcuts without ⌘ or ⌃ and ones
/// another menu item already uses.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    let defaultShortcut: KeyShortcut
    /// The menu item being changed, so its own shortcut doesn't count as taken.
    let action: Selector
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if let problem {
                Text(problem).foregroundStyle(.red).font(.callout)
            }
            if shortcut != defaultShortcut, !recording {
                Button("Reset") { shortcut = defaultShortcut; problem = nil }
                    .buttonStyle(.link)
            }
            Button(recording ? "Press a shortcut…" : shortcut.display) { recording ? stop() : start() }
                .monospacedDigit()
                .frame(minWidth: 130)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stop()
                return nil
            }
            guard let candidate = KeyShortcut(event), candidate.isUsable else {
                problem = "Use ⌘ or ⌃ with a key"
                return nil
            }
            if let taken = candidate.conflict(in: NSApp.mainMenu, ignoring: action) {
                problem = "\(candidate.display) is \(taken)"
                return nil
            }
            problem = nil
            shortcut = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
