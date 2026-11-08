import AgTermCore
import AppKit

extension MainWindowController {
    /// ⇧⌘P opens the command palette over the selected tab; pressing it again closes it.
    @objc func toggleCommandPalette() {
        guard commandPalette.superview == nil else { return hideCommandPalette() }
        // Read before the palette takes the keyboard, so items are enabled for the terminal, not the search field.
        let entries = tabEntries() + menuEntries(NSApp.mainMenu, path: [])
        commandPalette.translatesAutoresizingMaskIntoConstraints = false
        commandPalette.onClose = { [weak self] in self?.hideCommandPalette() }
        container.addSubview(commandPalette)
        let fill = commandPalette.widthAnchor.constraint(equalToConstant: CommandPalette.width)
        fill.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
        NSLayoutConstraint.activate([
            fill,
            commandPalette.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            commandPalette.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            commandPalette.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
        ])
        commandPalette.refreshAppearance()
        commandPalette.begin(entries)
    }

    func hideCommandPalette() {
        guard commandPalette.superview != nil else { return }
        commandPalette.removeFromSuperview()
        if let session = focusedSession { window?.makeFirstResponder(session.view) }
    }

    /// Every tab but the one you're typing in, in tab order.
    private func tabEntries() -> [PaletteEntry] {
        sessions.enumerated().compactMap { index, session in
            guard session !== focusedSession else { return nil }
            return PaletteEntry(title: session.topic, detail: "Tab · " + session.folder, shortcut: "") { [weak self] in
                self?.selectCard(index)
            }
        }
    }

    /// The menu's commands that can run now: no separators, hidden or disabled items, or the
    /// items that only open a submenu (their submenus' items are listed instead). Items without a
    /// target go to whatever in this window's responder chain handles them, as the menu would.
    func menuEntries(_ menu: NSMenu?, path: [String]) -> [PaletteEntry] {
        guard let menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu.items.flatMap { item -> [PaletteEntry] in
            guard !item.isSeparatorItem, !item.isHidden else { return [] }
            if let submenu = item.submenu {
                // The top level's titles are the menu bar ("Shell"); deeper ones read as a path.
                return menuEntries(submenu, path: path + [submenu.title.isEmpty ? item.title : submenu.title])
            }
            guard let action = item.action, action != #selector(toggleCommandPalette),
                  let target = target(for: action, item: item) else { return [] }
            let detail = path.joined(separator: " › ")
            return [PaletteEntry(title: item.title, detail: detail, shortcut: Self.shortcutText(item)) { [weak item] in
                guard let item else { return }
                NSApp.sendAction(action, to: target, from: item)
            }]
        }
    }

    /// Who runs the item now, or nil when it's disabled. Doesn't depend on this window being key.
    private func target(for action: Selector, item: NSMenuItem) -> AnyObject? {
        if let target = item.target { return item.isEnabled && target.responds(to: action) ? target : nil }
        var chain: [AnyObject] = []
        var responder = window?.firstResponder
        while let next = responder {
            chain.append(next)
            responder = next.nextResponder
        }
        chain += [window?.delegate, NSApp, NSApp.delegate].compactMap { $0 as AnyObject? }
        guard let target = chain.first(where: { $0.responds(to: action) }) else { return nil }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) ? target : nil }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) ? target : nil }
        return target
    }

    /// The shortcut as the menu shows it, such as ⇧⌘D.
    static func shortcutText(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var modifiers = item.keyEquivalentModifierMask
        // An uppercase key equivalent means Shift.
        if key != key.lowercased() { modifiers.insert(.shift) }
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let names: [String: String] = [
            "\t": "⇥", "\r": "↩", " ": "Space", "\u{1b}": "⎋",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
        ]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + (names[key] ?? key.uppercased())
    }
}
