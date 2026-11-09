import Foundation

/// How full an agent's context window is: the tokens its latest request sent, and the window's size.
public struct ContextUse: Equatable, Sendable {
    public let used: Int
    public let window: Int

    public init(used: Int, window: Int) {
        self.used = used
        self.window = window
    }

    /// From Grok's `signals.json`, which it writes beside the chat history when a turn ends.
    public init?(grokSignals text: String, model: String?) {
        guard let signals = JSONValue.parse(text), let used = signals["contextTokensUsed"]?.int, used > 0 else { return nil }
        let window = signals["contextWindowTokens"]?.int ?? 0
        self.init(used: used, window: window > 0 ? window : ContextWindow.size(model: model))
    }

    /// `412k / 1M`.
    public var text: String { "\(Self.tokens(used)) / \(Self.tokens(window))" }

    /// "940", "38k", "1M", "1.2M".
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = String(format: "%.1f", Double(count) / 1_000_000)
            return (millions.hasSuffix(".0") ? String(millions.dropLast(2)) : millions) + "M"
        }
        return count >= 1000 ? "\(Int((Double(count) / 1000).rounded()))k" : "\(count)"
    }
}

/// Context window sizes by model, as agmux's `getModelContextWindow` has them, for agents whose
/// transcript doesn't say (Claude Code; Codex and Grok report their own).
public enum ContextWindow {
    static let fallback = 200_000

    private static let suffixes = ["[1m]": 1_000_000, "[500k]": 500_000, "[400k]": 400_000, "[258k]": 258_000,
                                   "[200k]": 200_000, "[128k]": 128_000]

    private static let models = [
        "claude-fable-5": 1_000_000, "claude-opus-5": 1_000_000, "claude-opus-4-8": 1_000_000, "claude-opus-4-7": 1_000_000,
        "claude-opus-4-6": 1_000_000, "claude-opus-4-5": 200_000, "claude-sonnet-5": 1_000_000, "claude-sonnet-4-6": 1_000_000,
        "claude-haiku-4-5": 200_000, "opus": 1_000_000, "sonnet": 1_000_000, "haiku": 200_000, "opusplan": 1_000_000,
        "gpt-6.1-sol": 272_000, "gpt-6-astra": 272_000, "gpt-6-sol": 272_000, "gpt-6-luna": 272_000, "gpt-5.6-sol": 372_000,
        "gpt-5.6-terra": 372_000, "gpt-5.6-luna": 372_000, "gpt-5.4": 258_000, "gpt-5.4-mini": 272_000, "gpt-5.3-codex": 200_000,
        "gpt-5.2-codex": 200_000, "o4-mini": 200_000, "o3": 200_000, "codex-mini": 200_000,
        "grok-4.7": 500_000, "grok-4.7-build-fast": 500_000, "grok-4.6": 500_000, "grok-4.5": 500_000,
        "grok-composer-2.5-fast": 200_000, "grok-4.3": 256_000, "grok-build": 512_000,
    ]

    public static func size(model: String?) -> Int {
        guard let model, !model.isEmpty else { return fallback }
        if let suffix = suffixes.first(where: { model.hasSuffix($0.key) }) { return suffix.value }
        // `claude-opus-5-5[1m]` → `claude-opus-5-5`; `claude-haiku-4-5-20251001` → `claude-haiku-4-5`.
        let base = model.replacingOccurrences(of: #"\[.*\]$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if let known = models[base] { return known }
        // Newer versions of a family keep its window (Opus 5.5, Fable 5.2, Sonnet 5.5).
        if base.contains("haiku") { return 200_000 }
        if ["fable", "mythos", "opus", "sonnet"].contains(where: base.contains) { return 1_000_000 }
        return fallback
    }
}
