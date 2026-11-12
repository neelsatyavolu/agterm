import Foundation

/// Perch, the owner's browser (perch CLI and perchd). Agents started in agterm get Perch's MCP
/// server with their tab as the session, so the browser tabs they open are grouped under that
/// agent and the tab can show them. This file holds the parts with no AppKit.
public enum Perch {
    /// The client name agterm uses with perchd; each agterm tab is one session of it.
    public static let client = "agterm"

    /// The `perch mcp` server for an agent started in tab `tabID`, titled by its folder.
    public static func mcpServer(cli: String, agent: String, tabID: String, folder: String) -> MCPServer {
        let title = (folder as NSString).lastPathComponent
        return MCPServer(name: "perch", command: cli,
                         args: ["mcp", "--client", client, "--session", tabID, "--agent", agent, "--title", title], env: [:])
    }

    /// The tab id as a perchd session id, or nil when perchd wouldn't accept it.
    public static func sessionID(_ tabID: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard (1...80).contains(tabID.count), tabID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return tabID
    }

    /// What a tab's shell and the agents in it get, so every `perch` they run (the MCP server of
    /// a `perch skill install` entry too) works in this tab's session. Empty for a tab id perchd
    /// would refuse.
    public static func environment(tabID: String) -> [String: String] {
        guard let session = sessionID(tabID) else { return [:] }
        return ["PERCH_CLIENT": client, "PERCH_SESSION": session]
    }

    /// Whether a Codex config.toml's `perch` server is one `perch skill install` wrote (it runs
    /// `perch mcp --client …`). agterm replaces that one with its own for the tab; a hand-made one
    /// is the user's.
    public static func codexEntryIsPerchs(_ toml: String) -> Bool {
        if toml.contains("# perch:begin") { return true }
        var inPerch = false
        for line in toml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inPerch = trimmed == "[mcp_servers.perch]" || trimmed == "[mcp_servers.\"perch\"]"
                continue
            }
            if inPerch, trimmed.hasPrefix("args"), trimmed.contains("\"mcp\""), trimmed.contains("\"--client\"") { return true }
        }
        return false
    }

    /// Whether agterm adds its own `perch` server for `agent`. With none configured, yes. With
    /// one, only for Codex when `perch skill install` wrote it (a `-c` override replaces it);
    /// otherwise the agent keeps its own, which still works in the tab's session through
    /// PERCH_CLIENT and PERCH_SESSION.
    public static func addsServer(agent: String, configured: Set<String>, codexConfig: () -> String) -> Bool {
        guard configured.contains("perch") else { return true }
        return agent == "codex" && codexEntryIsPerchs(codexConfig())
    }

    /// Whether process `pid` is running (kill with signal 0; EPERM means it runs as someone else).
    public static func isRunning(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private struct SessionsFile: Decodable {
        struct Session: Decodable {
            let client: String
            let session: String
            let tabs: Int
        }
        let pid: Int32?
        let sessions: [Session]
    }

    /// Open Perch tabs per session of `client`, from perchd's `run/sessions.json`. Sessions
    /// without tabs are left out, and so is a file whose perchd is no longer running.
    public static func tabCounts(_ data: Data, client: String, isRunning: (Int32) -> Bool = Perch.isRunning) -> [String: Int] {
        guard let file = try? JSONDecoder().decode(SessionsFile.self, from: data) else { return [:] }
        if let pid = file.pid, !isRunning(pid) { return [:] }
        var counts: [String: Int] = [:]
        for session in file.sessions where session.client == client && session.tabs > 0 {
            counts[session.session, default: 0] += session.tabs
        }
        return counts
    }

    /// Where the `perch` command may be, best first: PERCH_CLI, the copy inside Perch.app (it ships
    /// as the `perchd` helper, which is the `perch` command), then the usual install places.
    public static func cliCandidates(environment: [String: String], appPath: String?, home: String) -> [String] {
        var candidates = [environment["PERCH_CLI"]].compactMap { $0 }
        if let appPath {
            candidates.append(appPath + "/Contents/Frameworks/Perch Framework.framework/Versions/Current/Helpers/perchd")
            candidates.append(appPath + "/Contents/MacOS/perch")
        }
        return candidates + [home + "/.local/bin/perch", "/opt/homebrew/bin/perch", "/usr/local/bin/perch"]
    }

    /// `perch` arguments that close the Perch tabs of agterm tab `tabID` (with PERCH_CLIENT=agterm).
    public static func endArguments(tabID: String) -> [String]? {
        sessionID(tabID).map { ["session", "end", "--session", $0] }
    }

    /// What agents with Perch's server are told, next to agterm's other instructions.
    public static let instructions = """
        ## Perch browser
        The perch MCP tools drive Perch, the user's own browser, where they are signed in to their sites.
        Use them for anything that needs a real browser or the user's accounts: reading a page that needs
        a login, checking a web app you are building, filling a form, or looking something up.
        - Your tabs open in a Perch tab group of their own, named after you and this folder, and close
          when you quit. Leave the user's other tabs alone unless they ask.
        - Perch asks the user before anything is sent, posted, bought or deleted. Say what you are about
          to do, and if a step waits for approval, tell the user to look at Perch.
        - In a shell in this tab, the `perch` command works in the same tab group (`perch --help`).
        """

    /// Links Perch should open: http and https only.
    public static func isWebLink(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
