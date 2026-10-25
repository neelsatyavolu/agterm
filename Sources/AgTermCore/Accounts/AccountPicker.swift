import Foundation

/// Picks the login to move to when the current one is out.
public enum AccountPicker {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let enabled: Bool
        public let reading: UsageReading?
        /// Known out until this time (from a limit hit), even if no reading says so yet.
        public let blockedUntil: Date?
        /// The last check failed (signed out, not a subscription): never move a session there.
        public let failed: Bool

        public init(id: String, enabled: Bool = true, reading: UsageReading?, blockedUntil: Date? = nil, failed: Bool = false) {
            self.id = id
            self.enabled = enabled
            self.reading = reading
            self.blockedUntil = blockedUntil
            self.failed = failed
        }

        func usable(_ now: Date) -> Bool {
            enabled && !(failed && reading == nil) && (blockedUntil.map { $0 <= now } ?? true) && reading?.exhaustedUntil(now) == nil
        }
    }

    /// The usable candidate with the most left; unknown usage ranks last. Ties keep list order,
    /// so your own login comes first.
    public static func next(_ candidates: [Candidate], excluding: Set<String>, now: Date) -> String? {
        candidates.enumerated()
            .filter { !excluding.contains($0.element.id) && $0.element.usable(now) }
            .max { a, b in
                let ra = a.element.reading?.remainingPercent ?? -1, rb = b.element.reading?.remainingPercent ?? -1
                return ra != rb ? ra < rb : a.offset > b.offset
            }?.element.id
    }
}
