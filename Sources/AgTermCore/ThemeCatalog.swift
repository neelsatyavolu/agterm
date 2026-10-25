import Foundation

/// An sRGB color as 0–255 components.
public struct RGB: Equatable, Sendable {
    public let r: UInt8, g: UInt8, b: UInt8

    public init(_ hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func channel(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `self` moved `amount` (0...1) of the way toward `other`.
    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        func lerp(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * amount).rounded()) }
        return RGB(r: lerp(r, other.r), g: lerp(g, other.g), b: lerp(b, other.b))
    }
}

public struct ThemePalette: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let bg: RGB
    public let fg: RGB
    public let accent: RGB
    public let ok: RGB
    public let danger: RGB
    /// ANSI 0–15.
    public let ansi: [RGB]

    /// Title bar and tab strip: the background nudged toward the text color.
    public var chrome: RGB { bg.mixed(with: fg, 0.045) }
}

public enum ThemeCatalog {
    public static let defaultID = "ink"

    public static let all: [ThemePalette] = [
        ThemePalette(
            id: "ink", name: "Ink", isDark: true,
            bg: RGB(0x0E0E0D), fg: RGB(0xF2F0EA), accent: RGB(0x4C8DFF), ok: RGB(0x4FBF85), danger: RGB(0xE5483A),
            ansi: [0x1E1E1C, 0xE56252, 0x6FC28B, 0xE3B867, 0x6B9EFF, 0xC493E0, 0x63C3C9, 0xD9D6CE,
                   0x6E6C66, 0xF07D6D, 0x8AD6A3, 0xF0CD85, 0x8DB5FF, 0xD4AEEC, 0x85D6DB, 0xF2F0EA].map(RGB.init)),
        ThemePalette(
            id: "paper", name: "Paper", isDark: false,
            bg: RGB(0xF7F5EF), fg: RGB(0x16161A), accent: RGB(0x2F6FE0), ok: RGB(0x2E8B57), danger: RGB(0xC8352A),
            ansi: [0x2B2B29, 0xC8352A, 0x2E7D4F, 0x8C6100, 0x2F6FE0, 0x8A4FB8, 0x1F7F84, 0xBDBAB2,
                   0x6E6C66, 0xD9483C, 0x3B9A63, 0xA87700, 0x4C8DFF, 0xA267D1, 0x2A9AA0, 0x16161A].map(RGB.init)),
        ThemePalette(
            id: "graphite", name: "Graphite", isDark: true,
            bg: RGB(0x1C1C1E), fg: RGB(0xE8E8E6), accent: RGB(0x6CA0FF), ok: RGB(0x5BC88E), danger: RGB(0xF0645A),
            ansi: [0x2C2C2E, 0xF0645A, 0x5BC88E, 0xE8C26E, 0x6CA0FF, 0xC79BE8, 0x5ECBD1, 0xD8D8D6,
                   0x77777A, 0xFF7E73, 0x7ADCA6, 0xF5D58C, 0x92BAFF, 0xDAB6F2, 0x84DEE3, 0xF5F5F3].map(RGB.init)),
        ThemePalette(
            id: "contrast", name: "Contrast", isDark: true,
            bg: RGB(0x050505), fg: RGB(0xFFFFFF), accent: RGB(0x5C9BFF), ok: RGB(0x3DDC84), danger: RGB(0xFF5A4F),
            ansi: [0x1A1A1A, 0xFF5A4F, 0x3DDC84, 0xFFD24D, 0x5C9BFF, 0xE08BFF, 0x4DE1E8, 0xE6E6E6,
                   0x808080, 0xFF7A70, 0x6BF0A3, 0xFFE07A, 0x85B5FF, 0xEBA8FF, 0x7EEEF3, 0xFFFFFF].map(RGB.init)),
        ThemePalette(
            id: "dusk", name: "Dusk", isDark: true,
            bg: RGB(0x1D1916), fg: RGB(0xEDE3D6), accent: RGB(0xE0A458), ok: RGB(0x9CC475), danger: RGB(0xE5735F),
            ansi: [0x2B2622, 0xE5735F, 0x9CC475, 0xE0A458, 0x7FA7D9, 0xC99AC4, 0x7EC0B4, 0xD6CCBF,
                   0x75695E, 0xF08B78, 0xB2D68E, 0xF0BC78, 0x9DBEE6, 0xDDB3D8, 0x9AD3C8, 0xF5EDE2].map(RGB.init)),
    ]

    public static func named(_ id: String) -> ThemePalette {
        all.first { $0.id == id } ?? all[0]
    }
}
