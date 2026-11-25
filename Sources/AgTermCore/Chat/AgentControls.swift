import Foundation

/// What the Chat composer's model and effort menu offers each agent, and what it types to
/// switch. Every switch is the agent's own slash command, so the terminal and the chat agree.
/// Where the CLI takes no argument (Codex's `/model`, Antigravity's), the menu opens the
/// agent's own picker instead, which the chat shows as a card you answer with the arrows.
public enum AgentControls {
    public struct Model: Equatable, Sendable {
        public let title: String
        /// What follows `/model `.
        public let argument: String

        public init(_ title: String, _ argument: String) {
            self.title = title
            self.argument = argument
        }
    }

    /// Claude Code's model aliases (2.1: `fable`, `opus`, `sonnet`, `haiku`).
    static let claudeModels = [Model("Fable", "fable"), Model("Opus", "opus"), Model("Sonnet", "sonnet"), Model("Haiku", "haiku")]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let grokEfforts = ["low", "medium", "high", "xhigh"]

    /// Models to pick from directly; empty when only the agent's picker can switch.
    /// `grokModels`: Grok's own list (`~/.grok/models_cache.json`, see `grokModels(cache:)`).
    public static func models(_ agent: TimelineFeed.Agent, grokModels: [Model] = []) -> [Model] {
        switch agent {
        case .claude: claudeModels
        case .grok: grokModels
        case .codex, .agy, .agl: []
        }
    }

    /// Effort levels to pick from directly; empty when the agent has none or only a picker.
    public static func efforts(_ agent: TimelineFeed.Agent) -> [String] {
        switch agent {
        case .claude: claudeEfforts
        case .grok: grokEfforts
        case .codex, .agy, .agl: []
        }
    }

    public static func modelCommand(_ model: Model) -> String { "/model " + model.argument }

    public static func effortCommand(_ level: String) -> String { "/effort " + level }

    /// What opens the agent's own model picker (agl's list of local models).
    public static func modelPicker(_ agent: TimelineFeed.Agent) -> String { agent == .agl ? "/models" : "/model" }

    /// What opens the agent's own effort picker, when it has one apart from its model picker.
    public static func effortPicker(_ agent: TimelineFeed.Agent) -> String? {
        switch agent {
        case .claude, .grok, .agy: "/effort"
        case .codex, .agl: nil
        }
    }

    /// Grok's models from its cache file: `{"models": {id: {"info": {"name": …}}}}`, the list
    /// sometimes stored as a JSON string. Sorted by name, newest version first.
    public static func grokModels(cache: Data) -> [Model] {
        guard let root = (try? JSONSerialization.jsonObject(with: cache)) as? [String: Any] else { return [] }
        var models = root["models"]
        if let text = models as? String { models = try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
        guard let table = models as? [String: Any] else { return [] }
        return table.compactMap { id, value -> Model? in
            let info = (value as? [String: Any])?["info"] as? [String: Any]
            return Model((info?["name"] as? String) ?? id, id)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
    }

    /// The effort Claude Code starts with when the transcript hasn't said yet (`effortLevel`).
    public static func claudeSettingsEffort(_ settings: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: settings)) as? [String: Any])?["effortLevel"] as? String
    }
}
