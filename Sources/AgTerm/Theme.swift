import AgTermCore
import AppKit

/// Colors and fonts for the active theme (see Settings). Surface fills (`bg`, `chrome`) carry the
/// window opacity; text colors never do. Defaults follow ~/DESIGN.md ("Ink").
enum Theme {
    private(set) static var palette = ThemeCatalog.named(ThemeCatalog.defaultID)
    private(set) static var opacity: CGFloat = 1
    private(set) static var settings = AppearanceSettings()

    static func apply(_ settings: AppearanceSettings) {
        self.settings = settings
        palette = settings.theme
        opacity = CGFloat(settings.opacity)
    }

    static func color(_ rgb: RGB, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: alpha)
    }

    /// Terminal and selected-tab background, at window opacity.
    static var bg: NSColor { color(palette.bg, alpha: opacity) }
    /// Title bar / tab strip, at window opacity.
    static var chrome: NSColor { color(palette.chrome, alpha: opacity) }
    static var fg: NSColor { color(palette.fg) }
    static var fg2: NSColor { color(palette.fg, alpha: 0.68) }
    static var fg3: NSColor { color(palette.fg, alpha: 0.45) }
    static var fg4: NSColor { color(palette.fg, alpha: 0.28) }
    static var surface: NSColor { color(palette.fg, alpha: 0.035) }
    static var surfaceHover: NSColor { color(palette.fg, alpha: 0.06) }
    static var border: NSColor { color(palette.fg, alpha: 0.10) }
    static var accent: NSColor { color(palette.accent) }
    static var accentMuted: NSColor { color(palette.accent, alpha: 0.45) }
    static var ok: NSColor { color(palette.ok) }
    static var danger: NSColor { color(palette.danger) }
    static var appearance: NSAppearance? { NSAppearance(named: palette.isDark ? .darkAqua : .aqua) }

    static var terminalFont: NSFont { terminalFont(family: settings.fontFamily, size: CGFloat(settings.fontSize)) }

    static func terminalFont(family: String?, size: CGFloat) -> NSFont {
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-pitch font families, for the Settings picker.
    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") }
        return Array(Set(families)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    static let topicFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let metaFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
}
