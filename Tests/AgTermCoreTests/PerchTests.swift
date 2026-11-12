import AgTermCore
import XCTest

final class PerchTests: XCTestCase {
    func testTheMCPServerNamesTheTabAsItsSession() {
        let server = Perch.mcpServer(cli: "/usr/local/bin/perch", agent: "claude", tabID: "3F2A-1", folder: "/Users/me/code/perch")
        XCTAssertEqual(server.name, "perch")
        XCTAssertEqual(server.command, "/usr/local/bin/perch")
        XCTAssertEqual(server.args, ["mcp", "--client", "agterm", "--session", "3F2A-1", "--agent", "claude", "--title", "perch"])
        XCTAssertEqual(server.env, [:])
    }

    func testTabIDsPerchCannotUseGetNoServer() {
        XCTAssertNil(Perch.sessionID("tab with spaces"))
        XCTAssertEqual(Perch.sessionID("8C1D4A3B-2E4F-4C1A-9B7E-1F2A3B4C5D6E"), "8C1D4A3B-2E4F-4C1A-9B7E-1F2A3B4C5D6E")
    }

    func testTabCountsComeFromPerchSessionsFileForAgtermOnly() throws {
        let json = """
        {"version":1,"updated":"2026-11-05T10:00:00Z","sessions":[
          {"client":"agterm","session":"T1","agent":"Claude Code","title":"perch","label":"Claude Code · perch","tabs":2,"asleep":false},
          {"client":"agterm","session":"T2","agent":"Codex","title":"x","label":"Codex · x","tabs":0,"asleep":false},
          {"client":"agmux","session":"T1","agent":"Codex","title":"y","label":"Codex · y","tabs":5,"asleep":false},
          {"client":"agterm","session":"T3","agent":"Grok","title":"z","label":"Grok · z","tabs":1,"asleep":true}
        ]}
        """
        let counts = Perch.tabCounts(Data(json.utf8), client: "agterm")
        XCTAssertEqual(counts, ["T1": 2, "T3": 1])
        XCTAssertEqual(Perch.tabCounts(Data("not json".utf8), client: "agterm"), [:])
    }

    func testOnlyWebLinksGoToPerch() {
        XCTAssertTrue(Perch.isWebLink("https://example.com/a"))
        XCTAssertTrue(Perch.isWebLink("HTTP://example.com"))
        XCTAssertFalse(Perch.isWebLink("file:///etc/hosts"))
        XCTAssertFalse(Perch.isWebLink("mailto:a@b.co"))
        XCTAssertFalse(Perch.isWebLink("/Users/me/notes.md"))
    }

    func testAFileLeftByADeadPerchdShowsNoTabs() {
        let json = #"{"version":1,"pid":4242,"sessions":[{"client":"agterm","session":"T1","tabs":2}]}"#
        XCTAssertEqual(Perch.tabCounts(Data(json.utf8), client: "agterm", isRunning: { _ in false }), [:])
        XCTAssertEqual(Perch.tabCounts(Data(json.utf8), client: "agterm", isRunning: { $0 == 4242 }), ["T1": 2])
        XCTAssertTrue(Perch.isRunning(getpid()))
    }

    func testTheTabEnvironmentNamesItsPerchSession() {
        XCTAssertEqual(Perch.environment(tabID: "3F2A-1"), ["PERCH_CLIENT": "agterm", "PERCH_SESSION": "3F2A-1"])
        XCTAssertEqual(Perch.environment(tabID: "bad id"), [:])
    }

    func testOnlyAPerchInstalledCodexEntryIsReplaced() {
        let installed = """
        model = "x"
        # perch:begin (added by `perch skill install codex`; `perch skill uninstall codex` removes it)
        [mcp_servers.perch]
        command = "/usr/local/bin/perch"
        args = ["mcp", "--client", "codex"]
        # perch:end
        """
        XCTAssertTrue(Perch.codexEntryIsPerchs(installed))
        XCTAssertTrue(Perch.codexEntryIsPerchs("[mcp_servers.perch]\nargs = [\"mcp\", \"--client\", \"codex\"]\n"))
        XCTAssertFalse(Perch.codexEntryIsPerchs("[mcp_servers.perch]\ncommand = \"/opt/my-perch\"\nargs = [\"serve\"]\n"))
        XCTAssertFalse(Perch.codexEntryIsPerchs("[mcp_servers.other]\nargs = [\"mcp\", \"--client\", \"x\"]\n"))
    }

    func testWithAPerchSkillInstallEntryTheTabSessionStillWins() {
        let installed = "# perch:begin\n[mcp_servers.perch]\nargs = [\"mcp\", \"--client\", \"codex\"]\n# perch:end\n"
        XCTAssertTrue(Perch.addsServer(agent: "claude", configured: [], codexConfig: { "" }))
        // Claude keeps its installed entry; the tab's PERCH_CLIENT/PERCH_SESSION point it at the tab.
        XCTAssertFalse(Perch.addsServer(agent: "claude", configured: ["perch"], codexConfig: { installed }))
        XCTAssertTrue(Perch.addsServer(agent: "codex", configured: ["perch"], codexConfig: { installed }))
        XCTAssertFalse(Perch.addsServer(agent: "codex", configured: ["perch"], codexConfig: { "[mcp_servers.perch]\ncommand = \"mine\"\n" }))
    }

    func testThePerchCommandIsFoundInsidePerchApp() {
        let found = Perch.cliCandidates(environment: [:], appPath: "/Applications/Perch.app", home: "/Users/me")
        XCTAssertEqual(found.first, "/Applications/Perch.app/Contents/Frameworks/Perch Framework.framework/Versions/Current/Helpers/perchd")
        XCTAssertTrue(found.contains("/Users/me/.local/bin/perch"))
        XCTAssertTrue(found.contains("/opt/homebrew/bin/perch"))
        // PERCH_CLI wins; without Perch.app only the install places are left.
        XCTAssertEqual(Perch.cliCandidates(environment: ["PERCH_CLI": "/x/perch"], appPath: "/Applications/Perch.app", home: "/h").first, "/x/perch")
        XCTAssertEqual(Perch.cliCandidates(environment: [:], appPath: nil, home: "/h").first, "/h/.local/bin/perch")
    }

    func testAgentsAreToldTheirTabsAreTheirOwn() {
        XCTAssertTrue(Perch.instructions.contains("Perch"))
        XCTAssertTrue(Perch.instructions.contains("signed in"))
        XCTAssertTrue(Perch.instructions.contains("ask"))
    }

    func testClosingATabsPerchTabsEndsItsSession() {
        XCTAssertEqual(Perch.endArguments(tabID: "3F2A-1"), ["session", "end", "--session", "3F2A-1"])
        XCTAssertNil(Perch.endArguments(tabID: "bad id"))
    }
}
