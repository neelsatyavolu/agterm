import Foundation

/// The branch's tracking state, from the `##` line of `git status --porcelain -b`.
public struct UpstreamState: Equatable, Sendable {
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public init(branch: String?, upstream: String?, ahead: Int, behind: Int) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

/// From `gh pr view --json number,url,state`.
public struct PullRequest: Equatable, Sendable, Decodable {
    public let number: Int
    public let url: String
    /// `OPEN`, `CLOSED` or `MERGED`.
    public let state: String

    public init(number: Int, url: String, state: String) {
        self.number = number
        self.url = url
        self.state = state
    }

    public var isOpen: Bool { state == "OPEN" }
}

/// Text for committing and opening pull requests: the requests sent to the fast model and
/// cleaning up what it sends back.
public enum GitPublish {
    /// Most of a diff a model sees; the stat line covers the rest.
    public static let patchBudget = 12_000

    public static let commitInstructions = """
    You write git commit messages. Reply with the message only: no quotes, no code fences, no preamble.
    First line: an imperative summary under 72 characters. If the recent subjects use a style \
    (such as "fix: …" or "feat: …"), use the same style. Add a blank line and a body of one to \
    four short lines only when the reason for the change isn't obvious from the summary.
    """

    public static let pullRequestInstructions = """
    You write GitHub pull request titles and descriptions. Reply with the title on the first line \
    (under 70 characters, plain text, no "Title:"), a blank line, then a markdown body: "## Summary" \
    with one to four bullets saying what changed and why, and "## Testing" only if the diff adds or \
    changes tests. No code fences around the reply, no preamble.
    """

    public static func commitRequest(stat: String, patch: String, recentSubjects: [String]) -> String {
        var parts: [String] = []
        if !recentSubjects.isEmpty { parts.append("Recent commit subjects:\n" + recentSubjects.map { "- " + $0 }.joined(separator: "\n")) }
        parts.append("Files:\n" + stat)
        parts.append("Diff:\n" + clip(patch))
        return parts.joined(separator: "\n\n")
    }

    public static func pullRequestRequest(commits: [String], stat: String, patch: String) -> String {
        ["Commits:\n" + commits.map { "- " + $0 }.joined(separator: "\n"), "Files:\n" + stat, "Diff:\n" + clip(patch)]
            .joined(separator: "\n\n")
    }

    /// The model's commit message without fences, quotes or a label; nil if empty.
    public static func cleanMessage(_ reply: String) -> String? {
        var text = withoutFences(reply)
        for label in ["commit message:", "message:"] where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        text = unquoted(text)
        return text.isEmpty ? nil : text
    }

    /// Title and body from the model's reply; nil if empty.
    public static func parsePullRequest(_ reply: String) -> (title: String, body: String)? {
        let text = withoutFences(reply)
        guard !text.isEmpty else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var title = lines[0].trimmingCharacters(in: .whitespaces)
        for prefix in ["title:", "# "] where title.lowercased().hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (unquoted(title), body)
    }

    /// A branch for changes committed on the default branch before opening a pull request:
    /// `agterm/` and the first five words of the subject, without its `type:` prefix.
    public static func branchName(forSubject subject: String) -> String {
        var text = subject
        if let colon = text.firstIndex(of: ":"), text[..<colon].allSatisfy({ $0.isLetter || "()-!".contains($0) }) {
            text = String(text[text.index(after: colon)...])
        }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(5).joined(separator: " ")
        let slug = WorktreeNames.branch(words)
        return "agterm/" + (slug.isEmpty ? "changes" : slug)
    }

    public static func upstream(statusHeader line: String) -> UpstreamState {
        var header = line.hasPrefix("## ") ? String(line.dropFirst(3)) : line
        if header.hasPrefix("HEAD (no branch)") { return UpstreamState(branch: nil, upstream: nil, ahead: 0, behind: 0) }
        let noCommits = "No commits yet on "
        if header.hasPrefix(noCommits) { header = String(header.dropFirst(noCommits.count)) }
        var counts = ""
        if let open = header.firstIndex(of: "[") {
            counts = String(header[open...])
            header = String(header[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let names = header.components(separatedBy: "...")
        func count(_ word: String) -> Int {
            guard let range = counts.range(of: word + " ") else { return 0 }
            return Int(counts[range.upperBound...].prefix(while: \.isNumber)) ?? 0
        }
        return UpstreamState(branch: names[0], upstream: names.count > 1 ? names[1] : nil, ahead: count("ahead"), behind: count("behind"))
    }

    public static func pullRequest(json: Data) -> PullRequest? { try? JSONDecoder().decode(PullRequest.self, from: json) }

    private static func clip(_ patch: String) -> String {
        patch.count <= patchBudget ? patch : String(patch.prefix(patchBudget)) + "\n… (diff cut here)"
    }

    private static func withoutFences(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last, first == last, "\"'`".contains(first) else { return text }
        return String(text.dropFirst().dropLast())
    }
}
