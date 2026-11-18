import Foundation

/// What a Grok conversation has used and changed, from the `usage.json` and `signals.json` Grok
/// writes beside its chat history when a turn ends. Grok prices its own turns, so no price table.
public struct GrokUsage: Equatable, Sendable {
    /// Input and output tokens, not counting cache reads (Grok's input includes them).
    public let tokens: Int
    public let costUSD: Double
    public let model: String?
    public let added: Int
    public let removed: Int

    /// Grok counts cost in ticks of 1e-10 USD (checked against its rates for grok-4.7-build-fast).
    static let ticksPerUSD = 10_000_000_000.0

    public init?(usage: String, signals: String?) {
        guard let session = JSONValue.parse(usage)?["session"] else { return nil }
        let input = session["inputTokens"]?.int ?? 0
        let cached = session["cachedReadTokens"]?.int ?? 0
        tokens = max(input - cached, 0) + (session["outputTokens"]?.int ?? 0)
        costUSD = Double(session["costUsdTicks"]?.int ?? 0) / Self.ticksPerUSD
        model = session["primaryModelId"]?.string
        let lines = signals.flatMap { JSONValue.parse($0) }
        // Grok has written a negative count; treat it as none.
        added = max(lines?["agentLinesAdded"]?.int ?? 0, 0)
        removed = max(lines?["agentLinesRemoved"]?.int ?? 0, 0)
    }
}
