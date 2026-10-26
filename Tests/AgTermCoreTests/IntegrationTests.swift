import XCTest
@testable import AgTermCore

final class AgmuxProjectTests: XCTestCase {
    let projects = [
        AgmuxProject(id: "p-root", repoPath: "/Users/sam/code"),
        AgmuxProject(id: "p-web", repoPath: "/Users/sam/code/web"),
        AgmuxProject(id: "p-api", repoPath: "/Users/sam/code/api"),
    ]

    func testLongestContainingProjectWins() {
        XCTAssertEqual(AgmuxProject.match("/Users/sam/code/web/src", in: projects)?.id, "p-web")
        XCTAssertEqual(AgmuxProject.match("/Users/sam/code/web", in: projects)?.id, "p-web")
        XCTAssertEqual(AgmuxProject.match("/Users/sam/code/tools", in: projects)?.id, "p-root")
    }

    func testPrefixMustEndAtAPathBoundary() {
        XCTAssertNil(AgmuxProject.match("/Users/sam/code-old/web", in: projects))
        XCTAssertEqual(AgmuxProject.match("/Users/sam/code/webby", in: projects)?.id, "p-root")
    }

    func testMemoryEnvMatchesAgmuxLayout() {
        let env = AgmuxProject(id: "p-web", repoPath: "/Users/sam/code/web").memoryEnv(home: "/Users/sam", sessionID: "agterm-1")
        XCTAssertEqual(env["AGMUX_PROJECT_ID"], "p-web")
        XCTAssertEqual(env["AGMUX_MEMORY_STORE"], "/Users/sam/.agmux/projects/p-web/memory.json")
        XCTAssertEqual(env["AGMUX_HANDOFF_STORE"], "/Users/sam/.agmux/projects/p-web/handoffs.json")
        XCTAssertEqual(env["AGMUX_MEMORY_MD"], "/Users/sam/code/web/.agmux/MEMORY.md")
        XCTAssertEqual(env["AGMUX_SESSIONS_MD"], "/Users/sam/code/web/.agmux/SESSIONS.md")
        XCTAssertEqual(env["AGMUX_SESSION_ID"], "agterm-1")
    }
}

final class AgentLaunchTests: XCTestCase {
    let memory = MCPServer(name: "agmux-memory", command: "/usr/local/bin/node", args: ["/A/memory.mjs"], env: ["AGMUX_PROJECT_ID": "p1"])
    let consult = MCPServer(name: "consult", command: "/usr/local/bin/node", args: ["/A/consult.mjs"], env: [:])

    func testClaudeGetsOneMCPConfigAndInstructions() throws {
        let args = try XCTUnwrap(AgentLaunch.claude(userArgs: ["--resume", "s"], servers: [memory, consult], instructions: "Use memory."))
        XCTAssertEqual(args.first, "--mcp-config")
        let json = try JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any]
        let servers = json?["mcpServers"] as? [String: [String: Any]]
        XCTAssertEqual(Set(servers?.keys.map { $0 } ?? []), ["agmux-memory", "consult"])
        XCTAssertEqual(servers?["agmux-memory"]?["command"] as? String, "/usr/local/bin/node")
        XCTAssertEqual(Array(args[2...]), ["--append-system-prompt", "Use memory.", "--resume", "s"])
        XCTAssertFalse(args.contains("--strict-mcp-config"), "the user's own MCP servers must stay")
    }

    func testClaudeKeepsTheUsersOwnSystemPrompt() throws {
        let args = try XCTUnwrap(AgentLaunch.claude(userArgs: ["--append-system-prompt", "mine"], servers: [memory], instructions: "Use memory."))
        XCTAssertEqual(args.filter { $0 == "--append-system-prompt" }.count, 1)
        XCTAssertEqual(args.suffix(2), ["--append-system-prompt", "mine"])
    }

    func testClaudeSubcommandsAreLeftAlone() {
        XCTAssertNil(AgentLaunch.claude(userArgs: ["mcp", "list"], servers: [memory], instructions: ""))
        XCTAssertNil(AgentLaunch.claude(userArgs: ["update"], servers: [memory], instructions: ""))
        XCTAssertNil(AgentLaunch.claude(userArgs: [], servers: [], instructions: "x"), "nothing to add")
        XCTAssertNotNil(AgentLaunch.claude(userArgs: ["fix the bug"], servers: [memory], instructions: ""))
    }

    func testCodexGetsInlineTomlOverrides() throws {
        let args = try XCTUnwrap(AgentLaunch.codex(userArgs: ["resume", "--last"], servers: [memory]))
        XCTAssertEqual(args, [
            "-c", #"mcp_servers.agmux-memory={ command = "/usr/local/bin/node", args = ["/A/memory.mjs"], env = { AGMUX_PROJECT_ID = "p1" } }"#,
            "resume", "--last",
        ])
    }

    func testTomlStringsAreEscaped() {
        let server = MCPServer(name: "x", command: #"/a "b"\c"#, args: [], env: [:])
        XCTAssertEqual(AgentLaunch.codex(userArgs: [], servers: [server])?[1], #"mcp_servers.x={ command = "/a \"b\"\\c", args = [], env = {  } }"#)
    }

    func testExistingServerNamesAreRead() {
        let toml = """
        model = "gpt-5"
        [mcp_servers.context7]
        command = "npx"
        [mcp_servers."consult"]
        [mcp_servers.firecrawl.env]
        """
        XCTAssertEqual(AgentLaunch.codexServerNames(toml), ["context7", "consult", "firecrawl"])
    }
}

final class StandaloneProjectTests: XCTestCase {
    private let repos: Set<String> = ["/Users/sam/code/web", "/Users/sam/code/web/vendor/lib"]

    func testFindsTheNearestGitRoot() {
        let project = AgmuxProject.standalone("/Users/sam/code/web/src/app", isRepoRoot: repos.contains)
        XCTAssertEqual(project?.repoPath, "/Users/sam/code/web")
        XCTAssertEqual(AgmuxProject.standalone("/Users/sam/code/web/vendor/lib/x", isRepoRoot: repos.contains)?.repoPath,
                       "/Users/sam/code/web/vendor/lib")
    }

    func testNoProjectOutsideARepo() {
        XCTAssertNil(AgmuxProject.standalone("/Users/sam/Downloads", isRepoRoot: repos.contains))
    }

    func testIDIsStablePerRepoAndNotAgmuxShaped() {
        let a = AgmuxProject.standalone("/Users/sam/code/web", isRepoRoot: repos.contains)
        let b = AgmuxProject.standalone("/Users/sam/code/web/src", isRepoRoot: repos.contains)
        let other = AgmuxProject.standalone("/Users/sam/code/web/vendor/lib", isRepoRoot: repos.contains)
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertNotEqual(a?.id, other?.id)
        XCTAssertTrue(a?.id.hasPrefix("agterm-") == true)
        XCTAssertEqual(a?.id.count, "agterm-".count + 16)
    }
}
