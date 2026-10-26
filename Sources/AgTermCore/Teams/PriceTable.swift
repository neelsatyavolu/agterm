import Foundation

/// USD per million tokens for one model. `cacheWrite` is the full charge for the
/// disjoint write class, not a surcharge on top of input.
struct Rates: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

/// agmux's built-in list prices (standard direct-API rates, verified through
/// 2026-09-29; agmux docs/teams-pricing-verification-2026-09-08.md). These win
/// over the OpenRouter catalog. Estimates, not invoices.
enum PriceTable {
    private static let rows: [([String], Rates)] = [
        (["grok-4.7", "grok-4.6"], Rates(input: 2.0, output: 6.0, cacheRead: 0.50, cacheWrite: 2.0)),
        (["grok-4.7-build-fast"], Rates(input: 4.0, output: 12.0, cacheRead: 1.0, cacheWrite: 4.0)),
        (["grok-4.5"], Rates(input: 2.0, output: 6.0, cacheRead: 0.30, cacheWrite: 2.0)),
        (["grok-build-0.1"], Rates(input: 1.0, output: 2.0, cacheRead: 0.20, cacheWrite: 1.0)),
        (["grok-4.3", "grok-4.20-multi-agent-0309", "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning"],
         Rates(input: 1.25, output: 2.50, cacheRead: 0.20, cacheWrite: 1.25)),
        (["claude-fable-5-1", "claude-mythos-5-1"], Rates(input: 10.0, output: 50.0, cacheRead: 0.25, cacheWrite: 12.50)),
        (["claude-fable-5", "claude-mythos-5"], Rates(input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.50)),
        (["claude-opus-5-5"], Rates(input: 4.0, output: 20.0, cacheRead: 0.20, cacheWrite: 5.0)),
        (["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"],
         Rates(input: 5.0, output: 25.0, cacheRead: 0.50, cacheWrite: 6.25)),
        (["claude-opus-4-1", "claude-opus-4"], Rates(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)),
        (["claude-sonnet-5-5", "claude-sonnet-5"], Rates(input: 2.0, output: 10.0, cacheRead: 0.20, cacheWrite: 2.50)),
        (["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4"], Rates(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)),
        (["claude-haiku-4-5"], Rates(input: 1.0, output: 5.0, cacheRead: 0.10, cacheWrite: 1.25)),
        (["claude-3-5-haiku"], Rates(input: 0.80, output: 4.0, cacheRead: 0.08, cacheWrite: 1.0)),
        (["gpt-6-astra"], Rates(input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.50)),
        (["gpt-6.1-sol"], Rates(input: 2.0, output: 10.0, cacheRead: 0.10, cacheWrite: 2.50)),
        (["gpt-6.1-terra"], Rates(input: 1.0, output: 5.0, cacheRead: 0.05, cacheWrite: 1.25)),
        (["gpt-6-sol"], Rates(input: 2.0, output: 10.0, cacheRead: 0.20, cacheWrite: 2.50)),
        (["gpt-6-luna"], Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)),
        (["gpt-5.6", "gpt-5.6-sol", "gpt-daybreak-blue-latest"], Rates(input: 4.0, output: 20.0, cacheRead: 0.40, cacheWrite: 5.0)),
        (["gpt-5.6-terra"], Rates(input: 2.0, output: 12.0, cacheRead: 0.20, cacheWrite: 2.50)),
        (["gpt-5.6-luna"], Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25)),
        (["gpt-5.5"], Rates(input: 5.0, output: 30.0, cacheRead: 0.50, cacheWrite: 5.0)),
        (["gpt-5.4", "gpt-5.4-2026-03-05"], Rates(input: 2.50, output: 15.0, cacheRead: 0.25, cacheWrite: 2.50)),
        (["gpt-5.4-mini"], Rates(input: 0.75, output: 4.50, cacheRead: 0.075, cacheWrite: 0.75)),
        (["gpt-5.4-nano"], Rates(input: 0.20, output: 1.25, cacheRead: 0.02, cacheWrite: 0.20)),
        (["gpt-5.1-codex-mini"], Rates(input: 0.25, output: 2.0, cacheRead: 0.025, cacheWrite: 0.25)),
        (["gpt-5.1-codex"], Rates(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25)),
        (["gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2"], Rates(input: 1.75, output: 14.0, cacheRead: 0.175, cacheWrite: 1.75)),
        (["o4-mini", "o4-mini-2025-04-16"], Rates(input: 1.10, output: 4.40, cacheRead: 0.275, cacheWrite: 1.10)),
        (["o3-mini", "o3-mini-2025-01-31"], Rates(input: 1.10, output: 4.40, cacheRead: 0.55, cacheWrite: 1.10)),
        (["o3"], Rates(input: 2.0, output: 8.0, cacheRead: 0.50, cacheWrite: 2.0)),
        (["o1"], Rates(input: 15.0, output: 60.0, cacheRead: 7.50, cacheWrite: 15.0)),
        (["gpt-4o-mini", "gpt-4o-mini-2024-07-18"], Rates(input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0.15)),
        (["gpt-4o", "gpt-4o-2024-08-06", "gpt-4o-2024-11-20"], Rates(input: 2.50, output: 10.0, cacheRead: 1.25, cacheWrite: 2.50)),
        (["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"], Rates(input: 0.40, output: 1.60, cacheRead: 0.10, cacheWrite: 0.40)),
        (["gpt-4.1-nano", "gpt-4.1-nano-2025-04-14"], Rates(input: 0.10, output: 0.40, cacheRead: 0.025, cacheWrite: 0.10)),
        (["gpt-4.1", "gpt-4.1-2025-04-14"], Rates(input: 2.0, output: 8.0, cacheRead: 0.50, cacheWrite: 2.0)),
    ]

    private static let byKey: [String: Rates] = Dictionary(
        rows.flatMap { names, rates in names.map { ($0, rates) } }, uniquingKeysWith: { first, _ in first })

    /// Per-request long-context step: `(largest short prompt, input ×, output ×)`.
    /// xAI switches at ≥ 200k, OpenAI above 272k; Claude has no premium.
    private static let openAILong: Set<String> = ["gpt-5.4", "gpt-5.4-2026-03-05", "gpt-5.5", "gpt-5.6", "gpt-5.6-sol",
        "gpt-daybreak-blue-latest", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna"]
    private static let grokLong: Set<String> = ["grok-4.7", "grok-4.6", "grok-4.5", "grok-build-0.1", "grok-4.3",
        "grok-4.20-multi-agent-0309", "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning"]

    /// Exact IDs only; family substrings once priced unknown variants. Never infer aliases.
    static func rates(model: String) -> Rates? {
        byKey[key(model)]
    }

    static func longContextStep(model: String) -> (threshold: Int, inputMultiplier: Double, outputMultiplier: Double)? {
        let k = key(model)
        if openAILong.contains(k) { return (272_000, 2.0, 1.5) }
        if grokLong.contains(k) { return (199_999, 2.0, 2.0) }
        return nil
    }

    /// Lowercased model ID with a known vendor prefix removed. Claude snapshots
    /// drop their 8-digit date and use `-` for `.`: they keep the same list price.
    static func key(_ model: String) -> String {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var bare = lower
        if let slash = lower.firstIndex(of: "/") {
            let vendor = lower[..<slash]
            let name = String(lower[lower.index(after: slash)...])
            let matches = (vendor == "openai" && (name.hasPrefix("gpt-") || name.hasPrefix("o")))
                || (vendor == "anthropic" && name.hasPrefix("claude-"))
                || ((vendor == "x-ai" || vendor == "xai") && name.hasPrefix("grok-"))
            if matches { bare = name }
        }
        if bare.hasPrefix("claude-") { return normalizeModelName(bare).replacingOccurrences(of: ".", with: "-") }
        return bare
    }

    /// Drops an 8-digit date suffix (`claude-opus-4-1-20250301` → `claude-opus-4-1`).
    static func normalizeModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dash = trimmed.lastIndex(of: "-") else { return trimmed }
        let suffix = trimmed[trimmed.index(after: dash)...]
        if suffix.utf8.count == 8, suffix.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            return String(trimmed[..<dash])
        }
        return trimmed
    }
}
