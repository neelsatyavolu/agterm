//
//  MinimumContrast.swift
//
//  agterm: keeps text readable when a program picks its colors for the other kind of
//  background (Claude Code's default dark theme draws white and pale gray, which vanish on a
//  light theme). See `TerminalView.minimumContrast`.
//
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TTColor {
    /// This color moved toward black or white, whichever contrasts more with `background`, just
    /// far enough to reach `ratio` (WCAG contrast, 1...21). Unchanged when it already does.
    func withMinimumContrast(_ ratio: CGFloat, against background: TTColor) -> TTColor {
        guard let fg = srgbComponents(), let bg = background.srgbComponents() else { return self }
        let bgLuminance = Self.luminance(bg.r, bg.g, bg.b)
        let contrast = { (r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat in
            let l = Self.luminance(r, g, b)
            return (max(l, bgLuminance) + 0.05) / (min(l, bgLuminance) + 0.05)
        }
        guard contrast(fg.r, fg.g, fg.b) < ratio else { return self }
        let target: CGFloat = contrast(1, 1, 1) >= contrast(0, 0, 0) ? 1 : 0
        let mix = { (t: CGFloat) in (fg.r + (target - fg.r) * t, fg.g + (target - fg.g) * t, fg.b + (target - fg.b) * t) }
        // Contrast grows monotonically with t, so bisect for the smallest step that's enough.
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<12 {
            let mid = (low + high) / 2
            let c = mix(mid)
            if contrast(c.0, c.1, c.2) >= ratio { high = mid } else { low = mid }
        }
        let c = mix(high)
        return TTColor.make(red: c.0, green: c.1, blue: c.2, alpha: fg.a)
    }

    private func srgbComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
#if os(macOS)
        guard let color = usingColorSpace(.sRGB) else { return nil }
#else
        let color = self
#endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
#endif
