import Foundation

/// A model ID as a tab shows it: "claude-opus-4-5-20251101" reads "Opus 4.5".
public enum ModelName {
    private static let claudeFamilies = ["opus", "sonnet", "haiku", "fable"]

    /// Claude IDs become family and version, GPT IDs read "GPT-5.1 Codex Max"; anything else
    /// (grok-4, o3) stays as it is, minus a trailing date. Nil for an empty ID or a placeholder like "<synthetic>".
    public static func short(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        // Bedrock and Vertex wrap the ID: "us.anthropic.claude-…-v1:0", "claude-…@20250514".
        var core = trimmed.lowercased()
        if let range = core.range(of: "claude-") { core = String(core[range.lowerBound...]) }
        core = String(core.split(separator: "@").first ?? Substring(core))
        core = String(core.split(separator: ":").first ?? Substring(core))
        let parts = core.split(separator: "-").map(String.init).filter { !isDate($0) && !($0.hasPrefix("v") && $0.dropFirst().allSatisfy(\.isNumber)) }
        if parts.first == "gpt", parts.count > 1 { return gpt(parts) }
        guard parts.first == "claude", let family = parts.first(where: claudeFamilies.contains) else {
            return parts.isEmpty ? trimmed : parts.joined(separator: "-")
        }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// "gpt-6.1-sol" reads "GPT-6.1 Sol".
    private static func gpt(_ parts: [String]) -> String {
        let suffix = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (["GPT-" + parts[1]] + suffix).joined(separator: " ")
    }

    private static func isDate(_ part: String) -> Bool {
        part.count == 8 && part.allSatisfy(\.isNumber)
    }
}
