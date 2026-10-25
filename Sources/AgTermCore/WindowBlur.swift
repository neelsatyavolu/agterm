import Foundation

/// How see-through windows blur what's behind them, like Terminal.app: the more transparent the
/// window, the stronger the blur, so text in windows behind never competes with your own.
public enum WindowBlur {
    public static let maxRadius = 48

    /// Background blur radius in points for a window at `opacity` with blur strength `blur` (0...1).
    public static func radius(opacity: Double, blur: Double) -> Int {
        guard opacity < 1, blur > 0 else { return 0 }
        let range = AppearanceSettings.opacityRange
        let transparency = min(max((1 - opacity) / (1 - range.lowerBound), 0), 1)
        return Int((blur * Double(maxRadius) * (0.4 + 0.6 * transparency)).rounded())
    }

    /// Full screen has nothing worth seeing behind it, so the window goes solid.
    public static func effectiveOpacity(_ opacity: Double, fullScreen: Bool) -> Double {
        fullScreen ? 1 : opacity
    }
}
