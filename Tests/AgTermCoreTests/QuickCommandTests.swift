import XCTest
@testable import AgTermCore

final class QuickCommandTests: XCTestCase {
    func testCleanStripsFencesAndPrompts() {
        XCTAssertEqual(QuickCommand.clean("```zsh\n$ du -sh * | sort -h\n```\n"), "du -sh * | sort -h")
        XCTAssertEqual(QuickCommand.clean("  ls -la  \n"), "ls -la")
        XCTAssertEqual(QuickCommand.clean("% git status"), "git status")
    }

    func testCleanJoinsLines() {
        XCTAssertEqual(QuickCommand.clean("mkdir out\ncd out"), "mkdir out && cd out")
        XCTAssertEqual(QuickCommand.clean("find . -name '*.log' \\\n  -delete"), "find . -name '*.log' -delete")
    }

    func testCleanRejectsEmpty() {
        XCTAssertNil(QuickCommand.clean(""))
        XCTAssertNil(QuickCommand.clean("```\n```"))
    }

    func testMessageSendsRecentCommandsAndOutput() {
        let output = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let message = QuickCommand.message(request: "fix it", cwd: "/tmp", shell: "zsh", output: output)
        XCTAssertTrue(message.contains("Recent terminal output"))
        XCTAssertTrue(message.contains("line 200"))
        XCTAssertTrue(message.contains("line \(200 - QuickCommand.outputLines + 1)\n"))
        XCTAssertFalse(message.contains("line \(200 - QuickCommand.outputLines)\n"))
        XCTAssertTrue(message.hasSuffix("Request: fix it"))
        XCTAssertFalse(QuickCommand.message(request: "x", cwd: "/", shell: "zsh", output: "").contains("output"))
    }

    func testMessageCapsLongOutputKeepingTheEnd() {
        let output = (1...100).map { "\($0) " + String(repeating: "x", count: 500) }.joined(separator: "\n")
        let message = QuickCommand.message(request: "x", cwd: "/", shell: "zsh", output: output)
        XCTAssertLessThan(message.count, QuickCommand.outputCharacters + 200)
        XCTAssertTrue(message.contains("100 xxx"))
        XCTAssertFalse(message.contains("\n1 xxx"))
    }

    func testPickPrefersChoiceThenFastest() {
        XCTAssertEqual(QuickCommand.pick(preferred: nil, installed: [.grok, .codex]), .codex)
        XCTAssertEqual(QuickCommand.pick(preferred: .grok, installed: [.grok, .claude]), .grok)
        XCTAssertEqual(QuickCommand.pick(preferred: .claude, installed: [.grok]), .grok)
        XCTAssertNil(QuickCommand.pick(preferred: nil, installed: []))
    }

    func testCodexFastModelReadsNewestLunaAndLowestEffort() throws {
        let json = """
            {"models":[
              {"slug":"gpt-6-sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"}]},
              {"slug":"gpt-6-luna","visibility":"list","supported_reasoning_levels":[{"effort":"minimal"},{"effort":"low"}]},
              {"slug":"gpt-5.6-luna","visibility":"list","supported_reasoning_levels":[{"effort":"low"}]}
            ]}
            """
        XCTAssertEqual(CodexFastModel.from(modelsCache: Data(json.utf8)), CodexFastModel(slug: "gpt-6-luna", effort: "minimal"))
        XCTAssertEqual(CodexFastModel.from(modelsCache: Data("{}".utf8)), .fallback)
    }

    func testArgumentsNeverAllowTools() {
        let claude = QuickCommand.arguments(.claude, message: "m")
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        let grok = QuickCommand.arguments(.grok, message: "m", sessionID: "s-1")
        XCTAssertEqual(grok[grok.firstIndex(of: "--session-id")! + 1], "s-1")
        XCTAssertEqual(grok[grok.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
        XCTAssertEqual(grok[grok.firstIndex(of: "--deny")! + 1], "*")
        XCTAssertEqual(grok[grok.firstIndex(of: "--max-turns")! + 1], "1")
        let codex = QuickCommand.arguments(.codex, message: "m", codex: CodexFastModel(slug: "gpt-6-luna", effort: "low"))
        XCTAssertEqual(codex[codex.firstIndex(of: "-s")! + 1], "read-only")
        XCTAssertEqual(codex[codex.firstIndex(of: "-m")! + 1], "gpt-6-luna")
        XCTAssertTrue(codex.contains("--ephemeral"))
        XCTAssertTrue(codex.contains("features.shell_tool=false"))
    }
}

final class PermissionBypassTests: XCTestCase {
    func testAddsEachAgentsFlag() {
        XCTAssertEqual(AgentKind.claude.bypassingPermissions([]), ["--dangerously-skip-permissions"])
        XCTAssertEqual(AgentKind.codex.bypassingPermissions(["fix the bug"]), ["--dangerously-bypass-approvals-and-sandbox", "fix the bug"])
        XCTAssertEqual(AgentKind.grok.bypassingPermissions(["-c"]), ["--permission-mode", "bypassPermissions", "-c"])
        XCTAssertEqual(AgentKind.claude.bypassingPermissions(["--resume", "abc"]), ["--dangerously-skip-permissions", "--resume", "abc"])
    }

    func testLeavesYourOwnChoiceAlone() {
        XCTAssertNil(AgentKind.claude.bypassingPermissions(["--dangerously-skip-permissions"]))
        XCTAssertNil(AgentKind.claude.bypassingPermissions(["--permission-mode", "plan"]))
        XCTAssertNil(AgentKind.codex.bypassingPermissions(["--sandbox=read-only"]))
        XCTAssertNil(AgentKind.codex.bypassingPermissions(["-a", "on-request"]))
        XCTAssertNil(AgentKind.codex.bypassingPermissions(["-sread-only"]))
        XCTAssertNil(AgentKind.codex.bypassingPermissions(["exec", "-aon-request", "hi"]))
        XCTAssertEqual(AgentKind.codex.bypassingPermissions(["exec", "hi"]), ["--dangerously-bypass-approvals-and-sandbox", "exec", "hi"])
        XCTAssertNil(AgentKind.grok.bypassingPermissions(["--always-approve"]))
    }

    func testSkipsUtilityCommands() {
        XCTAssertNil(AgentKind.claude.bypassingPermissions(["mcp", "list"]))
        XCTAssertNil(AgentKind.codex.bypassingPermissions(["login"]))
        XCTAssertNil(AgentKind.grok.bypassingPermissions(["models"]))
        XCTAssertNil(AgentKind.grok.bypassingPermissions(["--version"]))
    }

    func testRegistryCoversOtherCLIs() {
        XCTAssertEqual(AgentKind.named("gemini")?.bypassingPermissions(["-p", "hi"]), ["--yolo", "-p", "hi"])
        XCTAssertNil(AgentKind.named("gemini")?.bypassingPermissions(["-y"]))
        XCTAssertEqual(AgentKind.named("cursor-agent")?.bypassingPermissions([]), ["--force"])
        XCTAssertNil(AgentKind.named("opencode")?.bypassingPermissions(["run", "hi"]))
        XCTAssertNil(AgentKind.named("droid")?.bypassingPermissions([]), "no flag, so unchanged")
        XCTAssertEqual(AgentCatalog.agent(argv: ["/opt/homebrew/bin/kilocode"]), "kilo")
        XCTAssertEqual(AgentCatalog.agent(argv: ["cn"]), "continue")
        XCTAssertEqual(AgentCatalog.agent(argv: ["/Users/sam/.kimi-code/bin/kimi"]), "kimi")
        XCTAssertGreaterThanOrEqual(AgentKind.all.count, 20)
        XCTAssertEqual(Set(AgentKind.all.map(\.id)).count, AgentKind.all.count)
    }
}
