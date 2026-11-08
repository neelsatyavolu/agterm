import Foundation

/// The features agterm counts. The analytics service drops any other value, so adding one
/// means adding it to `AGTERM_FEATURES` there (docs/analytics-service-agterm.patch) and to the
/// list in Settings → General.
public enum AnalyticsFeature: String, CaseIterable, Sendable {
    case split
    case commandBar = "command_bar"
    case cloudTab = "cloud_tab"
    case phonePaired = "phone_paired"
    case updateInstalled = "update_installed"
}

/// One anonymous usage event. Only the constructors below make them, so a name or value
/// outside the allow-list can't be sent.
public struct AnalyticsEvent: Equatable, Sendable, Encodable {
    public let name: String
    public let props: [String: String]

    init(name: String, props: [String: String]) {
        self.name = name
        self.props = props
    }

    /// An agent agterm knows started in a tab; nil for anything else, so no other program's
    /// name is ever sent.
    public static func agentStarted(_ agentID: String) -> AnalyticsEvent? {
        guard AgentKind.named(agentID) != nil else { return nil }
        return AnalyticsEvent(name: "agent_started", props: ["agent": agentID])
    }

    public static func featureUsed(_ feature: AnalyticsFeature) -> AnalyticsEvent {
        AnalyticsEvent(name: "feature_used", props: ["feature": feature.rawValue])
    }

    /// An update was installed since the last launch; nil on a first launch or the same version.
    public static func updateInstalled(previous: String?, current: String) -> AnalyticsEvent? {
        guard let previous, previous != current else { return nil }
        return featureUsed(.updateInstalled)
    }
}

/// What the launch heartbeat says about this Mac, beyond the install ID.
public struct AnalyticsHeartbeat: Equatable, Sendable {
    public let appVersion: String
    public let osVersion: String
    public let arch: String

    public init(appVersion: String, osVersion: String, arch: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.arch = arch
    }
}

/// Request bodies for the analytics service. Every body names the app, so the service keeps
/// agterm's numbers apart from agmux's.
public enum AnalyticsPayload {
    static let app = "agterm"

    private struct Heartbeat: Encodable {
        let install_id: String
        let app: String
        let app_version: String
        let os_name: String
        let os_version: String
        let arch: String
        let channel: String
    }

    private struct Events: Encodable {
        let install_id: String
        let app: String
        let events: [AnalyticsEvent]
    }

    public static func heartbeat(installID: String, _ beat: AnalyticsHeartbeat) -> Data {
        encode(Heartbeat(install_id: installID, app: app, app_version: beat.appVersion, os_name: "macos",
                         os_version: beat.osVersion, arch: beat.arch, channel: "release"))
    }

    public static func events(installID: String, _ events: [AnalyticsEvent]) -> Data {
        encode(Events(install_id: installID, app: app, events: events))
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Strings and string maps only: encoding can't fail.
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// The random install ID: made on this Mac, tied to nothing else.
public enum AnalyticsInstallID {
    /// The stored ID if it is a random (version 4) UUID, otherwise a new one. Lowercase.
    public static func resolve(stored: String?) -> String {
        if let stored, isValid(stored) { return stored.lowercased() }
        return UUID().uuidString.lowercased()
    }

    public static func isValid(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return (uuid.uuid.6 >> 4) == 4
    }
}

/// Whether this run may send anything at all.
public enum AnalyticsGate {
    /// Only an opted-in release build that isn't a self-test or using a test state folder.
    public static func allowsSending(optedIn: Bool, isReleaseBuild: Bool, environment: [String: String]) -> Bool {
        optedIn && isReleaseBuild && environment["AGTERM_STATE_DIR"] == nil && environment["AGTERM_SELFTEST"] == nil
    }
}
