import Foundation

/// What the Settings window controls. Values are clamped on the way in, so a hand-edited or
/// corrupt defaults file can't produce an unreadable terminal.
public struct AppearanceSettings: Equatable, Sendable {
    public static let fontSizeRange: ClosedRange<Double> = 8...36
    public static let opacityRange: ClosedRange<Double> = 0.3...1

    public var themeID: String
    /// A monospaced font family name; nil means the system monospaced font (SF Mono).
    public var fontFamily: String?
    public var fontSize: Double { didSet { fontSize = Self.clamp(fontSize, Self.fontSizeRange) } }
    /// Background opacity, 1 = solid.
    public var opacity: Double { didSet { opacity = Self.clamp(opacity, Self.opacityRange) } }
    /// How strongly to blur what's behind a see-through window, 0 (off) to 1.
    public var blur: Double { didSet { blur = Self.clamp(blur, 0...1) } }

    public init(themeID: String = ThemeCatalog.defaultID, fontFamily: String? = nil, fontSize: Double = 13,
                opacity: Double = 1, blur: Double = 0.6) {
        self.themeID = themeID
        self.fontFamily = fontFamily
        self.fontSize = Self.clamp(fontSize, Self.fontSizeRange)
        self.opacity = Self.clamp(opacity, Self.opacityRange)
        self.blur = Self.clamp(blur, 0...1)
    }

    public var theme: ThemePalette { ThemeCatalog.named(themeID) }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.upperBound
    }

    // MARK: Persistence

    private enum Key {
        static let theme = "theme", fontFamily = "fontFamily", fontSize = "fontSize", opacity = "opacity", blurAmount = "blurAmount"
        /// 0.1.0's on/off toggle; read only when `blurAmount` was never saved.
        static let legacyBlur = "blur"
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppearanceSettings {
        let fallback = AppearanceSettings()
        return AppearanceSettings(
            themeID: defaults.string(forKey: Key.theme) ?? fallback.themeID,
            fontFamily: defaults.string(forKey: Key.fontFamily),
            fontSize: (defaults.object(forKey: Key.fontSize) as? NSNumber)?.doubleValue ?? fallback.fontSize,
            opacity: (defaults.object(forKey: Key.opacity) as? NSNumber)?.doubleValue ?? fallback.opacity,
            blur: (defaults.object(forKey: Key.blurAmount) as? NSNumber)?.doubleValue
                ?? legacyBlur(defaults.object(forKey: Key.legacyBlur) as? Bool, fallback: fallback.blur))
    }

    /// 0.1.0's toggle: on becomes full strength; off only meant it was never switched on,
    /// so it takes the new default rather than disabling blur.
    private static func legacyBlur(_ on: Bool?, fallback: Double) -> Double {
        on == true ? 1 : fallback
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(themeID, forKey: Key.theme)
        defaults.set(fontFamily, forKey: Key.fontFamily)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(opacity, forKey: Key.opacity)
        defaults.set(blur, forKey: Key.blurAmount)
    }
}
