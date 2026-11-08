import XCTest
@testable import AgTermCore

final class ProjectMemoryTests: XCTestCase {
    let agmux = [AgmuxProject(id: "p-web", repoPath: "/Users/sam/code/web")]
    let agtermDir = "/Users/sam/Library/Application Support/agterm/projects"
    let repoRoots: Set<String> = ["/Users/sam/code/web", "/Users/sam/code/other"]

    private func resolve(_ cwd: String, modified: [String: Date] = [:]) -> ProjectMemory? {
        ProjectMemory.resolve(cwd: cwd, agmuxProjects: agmux, home: "/Users/sam", agtermProjectsDir: agtermDir,
                              isRepoRoot: { self.repoRoots.contains($0) }, modified: { modified[$0] })
    }

    func testAgmuxProjectKeepsAgmuxStore() throws {
        let memory = try XCTUnwrap(resolve("/Users/sam/code/web/src"))
        XCTAssertEqual(memory.project.id, "p-web")
        XCTAssertEqual(memory.dataDir, "/Users/sam/.agmux/projects/p-web")
        let env = memory.env(sessionID: "agterm-1")
        XCTAssertEqual(env["AGMUX_MEMORY_STORE"], "/Users/sam/.agmux/projects/p-web/memory.json")
        XCTAssertEqual(env["AGMUX_MEMORY_MD"], "/Users/sam/code/web/.agmux/MEMORY.md")
    }

    func testOtherReposGetAgtermsOwnStore() throws {
        let memory = try XCTUnwrap(resolve("/Users/sam/code/other/lib"))
        XCTAssertTrue(memory.project.id.hasPrefix("agterm-"))
        XCTAssertEqual(memory.dataDir, agtermDir + "/" + memory.project.id)
        XCTAssertNil(resolve("/Users/sam/Downloads"), "no memory outside a repo agmux doesn't know")
    }

    func testTheStoreWrittenLastWinsWhenBothExist() throws {
        let own = try XCTUnwrap(AgmuxProject.standalone("/Users/sam/code/web") { self.repoRoots.contains($0) })
        let ownStore = agtermDir + "/" + own.id + "/memory.json"
        let agmuxStore = "/Users/sam/.agmux/projects/p-web/memory.json"
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        // Used without agmux by an older agterm, after agmux last wrote its store.
        XCTAssertEqual(resolve("/Users/sam/code/web", modified: [ownStore: new, agmuxStore: old])?.project.id, own.id)
        XCTAssertEqual(resolve("/Users/sam/code/web", modified: [ownStore: old, agmuxStore: new])?.project.id, "p-web")
        XCTAssertEqual(resolve("/Users/sam/code/web", modified: [ownStore: old])?.project.id, own.id,
                       "agterm's store has the memory and agmux's has none")
        XCTAssertEqual(resolve("/Users/sam/code/web", modified: [agmuxStore: old])?.project.id, "p-web")
    }
}

final class AgentMCPLaunchTests: XCTestCase {
    let memory = MCPServer(name: "agmux-memory", command: "/usr/local/bin/node", args: ["/A/memory.mjs"], env: ["AGMUX_PROJECT_ID": "p1"])
    let consult = MCPServer(name: "consult", command: "/usr/local/bin/node", args: ["/A/consult.mjs"], env: [:])

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testOpenCodeInlineConfig() throws {
        let text = try XCTUnwrap(AgentMCPLaunch.openCodeConfig(servers: [memory, consult], instructionsFile: "/S/memory.md"))
        let config = try object(text)
        let mcp = try XCTUnwrap(config["mcp"] as? [String: [String: Any]])
        XCTAssertEqual(Set(mcp.keys), ["agmux-memory", "consult"])
        XCTAssertEqual(mcp["agmux-memory"]?["type"] as? String, "local")
        XCTAssertEqual(mcp["agmux-memory"]?["command"] as? [String], ["/usr/local/bin/node", "/A/memory.mjs"])
        XCTAssertEqual(mcp["agmux-memory"]?["environment"] as? [String: String], ["AGMUX_PROJECT_ID": "p1"])
        XCTAssertEqual(mcp["agmux-memory"]?["enabled"] as? Bool, true)
        XCTAssertEqual(config["instructions"] as? [String], ["/S/memory.md"])
        XCTAssertNil(try object(XCTUnwrap(AgentMCPLaunch.openCodeConfig(servers: [consult], instructionsFile: nil)))["instructions"])
        XCTAssertNil(AgentMCPLaunch.openCodeConfig(servers: [], instructionsFile: "/S/memory.md"))
    }

    func testInlineConfigVariablePerAgent() {
        XCTAssertEqual(AgentMCPLaunch.inlineConfigVariable("opencode"), "OPENCODE_CONFIG_CONTENT")
        XCTAssertEqual(AgentMCPLaunch.inlineConfigVariable("kilo"), "KILO_CONFIG_CONTENT")
        XCTAssertEqual(AgentMCPLaunch.inlineConfigVariable("kilocode"), "KILO_CONFIG_CONTENT")
        XCTAssertNil(AgentMCPLaunch.inlineConfigVariable("amp"))
    }

    func testAmpGetsOneMCPConfigFlag() throws {
        let args = try XCTUnwrap(AgentMCPLaunch.amp(userArgs: ["-x", "hi"], servers: [memory]))
        XCTAssertEqual(args.first, "--mcp-config")
        XCTAssertEqual(Array(args[2...]), ["-x", "hi"])
        let servers = try object(args[1]) as? [String: [String: Any]]
        XCTAssertEqual(servers?["agmux-memory"]?["command"] as? String, "/usr/local/bin/node")
        XCTAssertEqual(servers?["agmux-memory"]?["args"] as? [String], ["/A/memory.mjs"])
        XCTAssertNil(servers?["mcpServers"], "amp takes the bare name → server map")
        XCTAssertNil(AgentMCPLaunch.amp(userArgs: ["mcp", "list"], servers: [memory]))
        XCTAssertNil(AgentMCPLaunch.amp(userArgs: ["--mcp-config", "{}"], servers: [memory]), "the user's own flag wins")
        XCTAssertNil(AgentMCPLaunch.amp(userArgs: [], servers: []))
    }

    func testCursorPluginFiles() throws {
        let files = AgentMCPLaunch.cursorPlugin(servers: [memory, consult], instructions: "Use memory.")
        XCTAssertEqual(try object(XCTUnwrap(files[".cursor-plugin/plugin.json"]))["name"] as? String, "agterm")
        let mcp = try object(XCTUnwrap(files["mcp.json"]))["mcpServers"] as? [String: [String: Any]]
        XCTAssertEqual(Set(mcp?.keys.map { $0 } ?? []), ["agmux-memory", "consult"])
        XCTAssertEqual(mcp?["agmux-memory"]?["env"] as? [String: String], ["AGMUX_PROJECT_ID": "p1"])
        let rule = try XCTUnwrap(files["rules/agterm-memory.mdc"])
        XCTAssertTrue(rule.hasPrefix("---\n"))
        XCTAssertTrue(rule.contains("alwaysApply: true"))
        XCTAssertTrue(rule.hasSuffix("Use memory.\n"))
        XCTAssertNil(AgentMCPLaunch.cursorPlugin(servers: [consult], instructions: "")["rules/agterm-memory.mdc"])
    }

    func testCursorArgs() {
        XCTAssertEqual(AgentMCPLaunch.cursor(userArgs: ["fix it"], pluginDir: "/P"), ["--plugin-dir", "/P", "fix it"])
        XCTAssertNil(AgentMCPLaunch.cursor(userArgs: ["mcp", "list"], pluginDir: "/P"))
        XCTAssertNil(AgentMCPLaunch.cursor(userArgs: ["login"], pluginDir: "/P"))
    }

    func testUsersOwnConfigFilesPerAgent() {
        let cwd = "/Users/sam/code/web"
        let amp = AgentMCPLaunch.configFiles(agent: "amp", home: "/Users/sam", cwd: cwd)
        XCTAssertTrue(amp.contains { $0.path == "/Users/sam/.config/amp/settings.json" && $0.key == "amp.mcpServers" })
        XCTAssertTrue(amp.contains { $0.path == cwd + "/.amp/settings.json" })
        let cursor = AgentMCPLaunch.configFiles(agent: "cursor-agent", home: "/Users/sam", cwd: cwd)
        XCTAssertTrue(cursor.contains { $0.path == "/Users/sam/.cursor/mcp.json" && $0.key == "mcpServers" })
        XCTAssertTrue(cursor.contains { $0.path == "/Users/sam/code/.cursor/mcp.json" }, "folders above count too")
        let opencode = AgentMCPLaunch.configFiles(agent: "opencode", home: "/Users/sam", cwd: cwd)
        XCTAssertTrue(opencode.contains { $0.path == "/Users/sam/.config/opencode/opencode.json" && $0.key == "mcp" })
        XCTAssertTrue(opencode.contains { $0.path == cwd + "/opencode.jsonc" })
        let kilo = AgentMCPLaunch.configFiles(agent: "kilo", home: "/Users/sam", cwd: cwd)
        XCTAssertTrue(kilo.contains { $0.path == "/Users/sam/.config/kilo/kilo.json" })
        XCTAssertTrue(AgentMCPLaunch.configFiles(agent: "grok", home: "/Users/sam", cwd: cwd).isEmpty)
    }

    func testServerNamesReadsJSONWithComments() {
        let text = """
        {
          // mine
          "amp.mcpServers": { "consult": { "command": "x" }, },
        }
        """
        XCTAssertEqual(AgentMCPLaunch.serverNames(Data(text.utf8), key: "amp.mcpServers"), ["consult"])
        let commented = "{ \"mcp\": { \"a\": { \"url\": \"http://x//y\" }, /* b */ \"c\": {}, // last\n } }"
        XCTAssertEqual(AgentMCPLaunch.serverNames(Data(commented.utf8), key: "mcp"), ["a", "c"])
        XCTAssertEqual(AgentMCPLaunch.serverNames(Data("not json".utf8), key: "mcp"), [])
    }

    func testSupportedAgents() {
        for id in ["claude", "codex", "opencode", "kilo", "cursor-agent", "amp"] {
            XCTAssertTrue(AgentMCPLaunch.supported.contains(id), id)
        }
        for id in ["grok", "gemini", "droid", "kimi", "cline"] {
            XCTAssertFalse(AgentMCPLaunch.supported.contains(id), id)
        }
    }
}
