import Foundation

/// agterm Remote with the Mac off: the cloud machine stands in for the Mac on the relay, under
/// the Mac's own desktop identity, so the phone keeps the same pairing and the same tab ids.
/// The Mac writes this file to the machine (`path`, in the user's home) when tabs move there,
/// and removes it when the phone remote is off.
public struct CloudPhoneHandoff: Codable, Equatable, Sendable {
    /// One cloud tab as the Mac shows it: its id, and the name you gave it, if any.
    public struct Tab: Codable, Equatable, Sendable {
        public var id: String
        public var name: String?

        public init(id: String, name: String?) {
            self.id = id
            self.name = name
        }
    }

    public static let path = ".agterm/phone.json"

    public var desktopId: String
    public var desktopSecret: String
    public var relay: String
    public var deviceName: String
    /// `ThemePalette.id` of the Mac's theme, for the phone's screen colors.
    public var theme: String
    /// The Mac's home, so folders show as `~/…` the same way.
    public var home: String
    /// The Mac's tab order.
    public var tabs: [Tab]

    public init(desktopId: String, desktopSecret: String, relay: String, deviceName: String, theme: String,
                home: String, tabs: [Tab]) {
        self.desktopId = desktopId
        self.desktopSecret = desktopSecret
        self.relay = relay
        self.deviceName = deviceName
        self.theme = theme
        self.home = home
        self.tabs = tabs
    }
}

/// When the cloud machine is the phone's desktop. The relay keeps one desktop per identity and
/// closes the older one with `replacedCode`, so the Mac and the machine must never both keep
/// reconnecting: the machine connects only once the Mac has been gone from the gateway for
/// `macGoneAfter`, and after the Mac takes the relay back it waits for the Mac to leave again.
public enum CloudPhoneRule {
    public static let macGoneAfter: TimeInterval = 20
    public static let replacedCode = 4000

    /// - Parameters:
    ///   - macConnected: a client is connected through the gateway (the Mac's tabs, or a move).
    ///   - macLastSeen: when the last client left (or the helper started).
    ///   - replacedAt: when the relay last replaced this machine's connection.
    public static func shouldConnect(hasHandoff: Bool, hasTabs: Bool, macConnected: Bool, macLastSeen: Date,
                                     replacedAt: Date?, now: Date, goneAfter: TimeInterval = macGoneAfter) -> Bool {
        guard hasHandoff, hasTabs, !macConnected else { return false }
        if let replacedAt, replacedAt >= macLastSeen { return false }
        return now.timeIntervalSince(macLastSeen) >= goneAfter
    }
}
