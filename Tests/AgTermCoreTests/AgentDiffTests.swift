import XCTest
@testable import AgTermCore

final class AgentCatalogTests: XCTestCase {
    func testNativeAgentBinaries() {
        XCTAssertEqual(AgentCatalog.agent(argv: ["/Users/sam/.local/bin/claude", "--resume", "x"]), "claude")
        XCTAssertEqual(AgentCatalog.agent(argv: ["codex"]), "codex")
        XCTAssertEqual(AgentCatalog.agent(argv: ["grok", "-m", "grok-4"]), "grok")
        XCTAssertEqual(AgentCatalog.agent(argv: ["cursor-agent"]), "cursor-agent")
    }

    func testScriptAgentsRunByAnInterpreter() {
        XCTAssertEqual(AgentCatalog.agent(argv: ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"]), "gemini")
        XCTAssertEqual(AgentCatalog.agent(argv: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), "claude")
        XCTAssertEqual(AgentCatalog.agent(argv: ["/usr/bin/python3", "/Users/sam/.local/bin/aider"]), "aider")
    }

    func testOtherProgramsAreNotAgents() {
        XCTAssertNil(AgentCatalog.agent(argv: ["vim", "claude.md"]))
        XCTAssertNil(AgentCatalog.agent(argv: ["node", "server.js"]))
        XCTAssertNil(AgentCatalog.agent(argv: ["zsh"]))
        XCTAssertNil(AgentCatalog.agent(argv: []))
    }
}

final class LineCountTests: XCTestCase {
    func testCountsLinesIncludingUnterminatedLast() {
        XCTAssertEqual(LineCount.of(Data("a\nb\nc".utf8)), 3)
        XCTAssertEqual(LineCount.of(Data("a\nb\n".utf8)), 2)
        XCTAssertEqual(LineCount.of(Data()), 0)
    }

    func testBinaryFilesCountAsZero() {
        XCTAssertEqual(LineCount.of(Data([0x89, 0x50, 0x00, 0x0A, 0x0A])), 0)
    }
}
