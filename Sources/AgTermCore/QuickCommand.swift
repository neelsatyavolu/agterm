import Foundation

/// The small, fast model ⌘K asks for a shell command, run through the CLI you're already signed in to.
public enum QuickModel: String, CaseIterable, Sendable {
    case claude, codex, grok

    /// Automatic picks the first one installed, in this order (fastest first: about 2.5 s, 4 s, 5 s).
    public static let preference: [QuickModel] = [.claude, .codex, .grok]

    public var cli: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Haiku"
        case .codex: "Codex Luna"
        case .grok: "Grok"
        }
    }

    /// Short name shown in the command bar.
    public var shortName: String {
        switch self {
        case .claude: "Haiku"
        case .codex: "Luna"
        case .grok: "Grok"
        }
    }
}

/// Codex model and lowest reasoning effort to use, read from Codex's own model list.
public struct CodexFastModel: Equatable, Sendable {
    public let slug: String?
    public let effort: String

    public init(slug: String?, effort: String) {
        self.slug = slug
        self.effort = effort
    }

    public static let fallback = CodexFastModel(slug: nil, effort: "low")

    /// The newest listed "luna" model in ~/.codex/models_cache.json (Codex lists newest first),
    /// at the lowest effort it supports.
    public static func from(modelsCache data: Data) -> CodexFastModel {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return fallback }
        let luna = models.first { model in
            (model["slug"] as? String)?.contains("luna") == true && (model["visibility"] as? String ?? "list") == "list"
        }
        guard let luna, let slug = luna["slug"] as? String else { return fallback }
        let levels = (luna["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
        return CodexFastModel(slug: slug, effort: levels.first ?? "low")
    }
}

public enum QuickCommand {
    public static let instructions = """
        You write one shell command for a macOS terminal. Reply with only the command on a single line: \
        no explanation, no code fences, no leading $. Prefer standard macOS and BSD tools. \
        If the request is unclear or unsafe, reply with a harmless `echo` saying why.
        """

    /// Lines of the screen sent along, so "fix that error" has something to go on.
    public static let screenLines = 20

    /// The message sent to the model.
    public static func message(request: String, cwd: String, shell: String, screen: String) -> String {
        let recent = screen.split(separator: "\n", omittingEmptySubsequences: true).suffix(screenLines).joined(separator: "\n")
        var text = "Shell: \(shell) on macOS\nFolder: \(cwd)\n"
        if !recent.isEmpty { text += "Last lines on screen:\n\(recent)\n" }
        return text + "Request: \(request)"
    }

    /// The model's preference if it's installed, else the first installed in `QuickModel.preference`.
    public static func pick(preferred: QuickModel?, installed: Set<QuickModel>) -> QuickModel? {
        if let preferred, installed.contains(preferred) { return preferred }
        return QuickModel.preference.first(where: installed.contains)
    }

    /// CLI arguments for a one-shot answer with no tools and no MCP servers. Claude and Codex keep
    /// no session; Grok always saves one, so it gets `sessionID` for deleting afterwards.
    public static func arguments(_ model: QuickModel, message: String, codex: CodexFastModel = .fallback,
                                 sessionID: String = UUID().uuidString.lowercased()) -> [String] {
        switch model {
        case .claude:
            return ["-p", "--model", "haiku", "--system-prompt", instructions, "--tools", "",
                    "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "",
                    "--no-session-persistence", message]
        case .codex:
            var args = ["exec"]
            if let slug = codex.slug { args += ["-m", slug] }
            return args + ["-c", "model_reasoning_effort=\"\(codex.effort)\"", "-c", "mcp_servers={}",
                           "-c", "features.plugins=false", "-c", "features.shell_tool=false", "-c", "web_search=\"disabled\"",
                           "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
                           instructions + "\n\n" + message]
        case .grok:
            // dontAsk alone still let tools run (checked with Grok 1.0.70); deny every tool outright.
            return ["-p", message, "--effort", "low", "--system-prompt-override", instructions, "--max-turns", "1",
                    "--permission-mode", "dontAsk", "--deny", "*", "--disable-web-search", "--no-subagents", "--no-plan",
                    "--session-id", sessionID]
        }
    }

    /// The command in a model's reply: fences, prompts and blank lines removed, lines joined into one.
    public static func clean(_ output: String) -> String? {
        var lines = output.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            let rest = lines[(open + 1)...]
            let close = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) ?? lines.endIndex
            lines = Array(lines[(open + 1)..<close])
        }
        let commands = lines.map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            for prompt in ["$ ", "% "] where line.hasPrefix(prompt) { line.removeFirst(prompt.count) }
            return line
        }.filter { !$0.isEmpty }
        guard !commands.isEmpty else { return nil }
        // A trailing backslash continues the line; separate commands run one after another.
        var joined = ""
        for line in commands {
            if joined.hasSuffix("\\") {
                joined.removeLast()
                joined += line
            } else {
                joined += joined.isEmpty ? line : " && " + line
            }
        }
        let single = joined.trimmingCharacters(in: .whitespaces)
        return single.isEmpty ? nil : single
    }
}
