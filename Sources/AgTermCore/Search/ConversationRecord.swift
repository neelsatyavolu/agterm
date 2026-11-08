import Foundation

/// One past conversation found on disk, with the words in it that search looks through: your
/// prompts and the agent's replies, without tool output or the context agents add on their own.
public struct ConversationRecord: Codable, Equatable, Sendable {
    public var agent: AccountProvider
    /// The id its agent resumes it by.
    public var id: String
    /// The transcript file (Grok: the conversation's chat_history.jsonl).
    public var path: String
    /// The login whose own folder holds it; nil when it's in yours, shared by every login.
    public var account: String?
    /// Where it ran; the resumed tab opens there.
    public var folder: String?
    /// The agent's own name for it (Claude Code's ai-title, a Codex thread name, Grok's summary).
    public var title: String?
    public var firstPrompt: String?
    public var modified: Date
    public var size: Int64
    /// How far the transcript has been read: the end of its last complete line.
    public var parsed: Int64
    /// One message per line, whitespace collapsed, UTF-8.
    public var text: Data

    public init(agent: AccountProvider, id: String, path: String, account: String?, modified: Date, size: Int64) {
        self.agent = agent
        self.id = id
        self.path = path
        self.account = account
        self.modified = modified
        self.size = size
        parsed = 0
        text = Data()
    }

    /// What the result list shows as its name.
    public var displayTitle: String {
        let name = title ?? firstPrompt ?? ""
        return name.isEmpty ? "Untitled conversation" : name
    }

    /// The most text kept for one conversation; past it, only the title is still updated.
    static let maxText = 2 << 20

    mutating func append(_ message: String) {
        guard text.count < Self.maxText else { return }
        let flat = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return }
        if !text.isEmpty { text.append(0x0A) }
        text.append(contentsOf: flat.utf8)
    }
}

/// Where one agent keeps conversations, and the login that folder belongs to.
public struct ConversationRoot: Equatable, Sendable {
    public let agent: AccountProvider
    /// ~/.claude/projects, ~/.codex/sessions or ~/.grok/sessions (or a login's own).
    public let url: URL
    public let account: String?

    public init(agent: AccountProvider, url: URL, account: String?) {
        self.agent = agent
        self.url = url
        self.account = account
    }
}

/// The command that reopens a conversation, built the way restore and account switching build it.
public enum ConversationResume {
    public static func command(_ record: ConversationRecord) -> String? {
        guard ConversationParser.isSessionID(record.id) else { return nil }
        let resume: String?
        switch record.agent {
        case .claude: resume = AgentResume.commandLine(argv: ["claude"], claudeSessionID: record.id)
        case .codex: resume = AgentResume.codexCommandLine(userArgs: [], sessionID: record.id)
        case .grok: resume = AgentResume.grokCommandLine(userArgs: [], sessionID: record.id)
        }
        guard let resume else { return nil }
        // A login's own folder: name it on the command, as an account switch does.
        return record.account.map { "AGTERM_ACCOUNT=\(ShellEscape.path($0)) " + resume } ?? resume
    }
}
