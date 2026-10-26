import AgTermCore
import SwiftUI

/// agterm's Ink look: warm ink-black, warm off-white, one blue accent, flat and square.
/// The terminal itself uses whichever theme the Mac uses (`ScreenSnapshot.theme`).
enum Ink {
    static let palette = ThemeCatalog.named(ThemeCatalog.defaultID)

    static let bg = Color(palette.bg)
    static let fg = Color(palette.fg)
    static let fg2 = fg.opacity(0.68)
    static let fg3 = fg.opacity(0.45)
    static let fg4 = fg.opacity(0.28)
    static let surface = fg.opacity(0.035)
    static let surfaceHover = fg.opacity(0.06)
    static let border = fg.opacity(0.10)
    static let borderStrong = fg.opacity(0.22)
    static let accent = Color(palette.accent)
    static let accentMuted = accent.opacity(0.45)
    static let ok = Color(palette.ok)
    static let danger = Color(palette.danger)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Mono, uppercase, tracked: the label style.
    static let label = mono(11, .medium)
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

extension TabStatus {
    /// Same colors as the Mac's tab cards.
    var color: Color {
        switch self {
        case .idle: Ink.fg4
        case .working: Ink.accent
        case .done: Ink.ok
        case .waiting: Ink.fg
        case .exited: Ink.fg3
        }
    }
}

/// A 1px rule.
struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.border).frame(height: 1) }
}

/// Flat, square buttons: primary (fg on bg), ghost (outlined), accent (one per view).
struct InkButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, accent }
    var kind: Kind = .ghost

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(kind == .ghost ? Ink.fg : Ink.bg)
            .background(background.opacity(configuration.isPressed ? 0.8 : 1))
            .overlay(Rectangle().stroke(kind == .ghost ? Ink.borderStrong : .clear, lineWidth: 1))
            .contentShape(Rectangle())
    }

    private var background: Color {
        switch kind {
        case .primary: Ink.fg
        case .ghost: .clear
        case .accent: Ink.accent
        }
    }
}
