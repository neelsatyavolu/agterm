import Foundation

/// Recognises coding-agent CLIs from a process's argv.
public enum AgentCatalog {
    /// Command names from `AgentKind.all`, plus the package folder names some install under
    /// when run by node or python.
    private static let names: [String: String] = {
        var names = ["claude-code": "claude", "gemini-cli": "gemini", "qwen-code": "qwen", "kilocode": "kilo"]
        for agent in AgentKind.all {
            for command in agent.commands { names[command] = agent.id }
        }
        return names
    }()
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "uv", "uvx"]

    /// The agent's short name, or nil for anything else.
    public static func agent(argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let program = (first as NSString).lastPathComponent
        if let name = names[program] { return name }
        guard interpreters.contains(program) || program.hasPrefix("python"), argv.count > 1 else { return nil }
        // e.g. node …/node_modules/@google/gemini-cli/dist/index.js, or python …/bin/aider
        for component in (argv[1] as NSString).pathComponents.reversed() {
            if let name = names[component] { return name }
        }
        return nil
    }
}

public enum LineCount {
    /// Lines in a text file; binary files (any NUL byte) count as 0.
    public static func of(_ data: Data) -> Int {
        guard !data.isEmpty, !data.contains(0) else { return 0 }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last == 0x0A ? newlines : newlines + 1
    }
}
