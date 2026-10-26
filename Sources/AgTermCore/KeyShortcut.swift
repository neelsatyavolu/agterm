import Foundation

/// A menu shortcut you can change in Settings: one printable key plus modifiers.
public struct KeyShortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public static let newAgentTabDefault = KeyShortcut(key: "t", modifiers: [.command, .option])

    /// Lowercase; shift is in `modifiers`, as menus expect.
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// ⌃⌥⇧⌘ then the key, the order menus show them in.
    public var display: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }

    /// Needs ⌘ or ⌃, so it can't take over ordinary typing, and one visible character.
    public var isUsable: Bool {
        guard !modifiers.isDisjoint(with: [.command, .control]), key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first else { return false }
        return (33...126).contains(scalar.value)
    }

    // MARK: Persistence

    public static func load(from defaults: UserDefaults = .standard, key defaultsKey: String, fallback: KeyShortcut) -> KeyShortcut {
        guard let saved = defaults.dictionary(forKey: defaultsKey), let key = saved["key"] as? String,
              let raw = saved["modifiers"] as? Int else { return fallback }
        let shortcut = KeyShortcut(key: key, modifiers: Modifiers(rawValue: raw))
        return shortcut.isUsable ? shortcut : fallback
    }

    public func save(to defaults: UserDefaults = .standard, key defaultsKey: String) {
        defaults.set(["key": key, "modifiers": modifiers.rawValue] as [String: Any], forKey: defaultsKey)
    }
}
