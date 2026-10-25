import AppKit
import Darwin

/// Blurs whatever is behind a see-through window with a chosen radius, the way Terminal.app,
/// iTerm2 and Alacritty do. Uses the window server's CGSSetWindowBackgroundBlurRadius, looked up
/// at runtime; `isAvailable` is false if a future macOS drops it, and callers fall back to
/// NSVisualEffectView.
enum BackgroundBlur {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, UInt32, Int32) -> Int32

    private static let functions: (MainConnectionID, SetBlurRadius)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let setRadius = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(connection, to: MainConnectionID.self), unsafeBitCast(setRadius, to: SetBlurRadius.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// Returns false when the radius couldn't be applied (no window server window yet, or no API).
    @discardableResult
    static func set(_ window: NSWindow, radius: Int) -> Bool {
        guard let (connection, setRadius) = functions, window.windowNumber > 0 else { return false }
        return setRadius(connection(), UInt32(window.windowNumber), Int32(radius)) == 0
    }
}
