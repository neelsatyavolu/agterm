@testable import AgTermCore
import XCTest

final class SlashCatalogTests: XCTestCase {
    private var root: URL!
    private var homes: SlashCatalog.Homes!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slash-\(UUID().uuidString)")
        let user = root.appendingPathComponent("home")
        homes = SlashCatalog.Homes(user: user, claude: user.appendingPathComponent(".claude"),
                                   codex: user.appendingPathComponent(".codex"), grok: user.appendingPathComponent(".grok"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Query and matching

    func testQueryOnlyWhileTypingTheName() {
        XCTAssertEqual(SlashMenu.query("/"), "")
        XCTAssertEqual(SlashMenu.query("/workf"), "workf")
        XCTAssertEqual(SlashMenu.query("/vercel:work"), "vercel:work")
        XCTAssertNil(SlashMenu.query("/model opus"))
        XCTAssertNil(SlashMenu.query("hello /model"))
        XCTAssertNil(SlashMenu.query("/usr/bin"))
        XCTAssertNil(SlashMenu.query(""))
    }

    func testPrefixMatchesComeFirstThenPluginPartThenFuzzy() {
        let commands = [SlashCommand("vercel:workflow", ""), SlashCommand("review", ""), SlashCommand("workflow-authoring", ""),
                        SlashCommand("workflows", ""), SlashCommand("wrap-flow", "")]
        let names = SlashMenu.matches("workf", in: commands).map(\.name)
        XCTAssertEqual(names, ["workflow-authoring", "workflows", "vercel:workflow"])
        XCTAssertEqual(SlashMenu.matches("wf", in: commands).map(\.name).first, "wrap-flow", "word starts beat a run")
        XCTAssertFalse(SlashMenu.matches("wf", in: commands).map(\.name).contains("review"))
        XCTAssertEqual(SlashMenu.matches("", in: commands).count, commands.count)
    }

    func testCompletionLeavesRoomForArguments() {
        XCTAssertEqual(SlashMenu.completion(SlashCommand("model", "")), "/model ")
    }

    // MARK: Frontmatter

    func testFrontmatterReadsQuotedAndFoldedValues() {
        let text = "---\nname: deploy\ndescription: \"Ship it: now\"\nwhen: >\n  first\n  second\n---\n# Body\n"
        let fields = Frontmatter.fields(text)
        XCTAssertEqual(fields["name"], "deploy")
        XCTAssertEqual(fields["description"], "Ship it: now")
        XCTAssertEqual(fields["when"], "first second")
        XCTAssertEqual(Frontmatter.firstLine(text), "Body")
        XCTAssertEqual(Frontmatter.fields("no frontmatter"), [:])
    }

    // MARK: Claude

    func testClaudeReadsProjectUserAndEnabledPlugins() throws {
        try write("repo/.git/HEAD", "ref")
        try write("repo/.claude/skills/ship/SKILL.md", "---\nname: ship\ndescription: Project ship\n---\n")
        try write("repo/.claude/commands/fix.md", "Fix the build\n")
        try write("home/.claude/skills/ship/SKILL.md", "---\nname: ship\ndescription: Mine\n---\n")
        try write("home/.claude/skills/hidden/SKILL.md", "---\nuser-invocable: false\n---\n")
        try write("home/.claude/commands/git/push.md", "---\ndescription: Push it\n---\n")
        let plugin = root.appendingPathComponent("plugins/vercel").path
        let other = root.appendingPathComponent("plugins/off").path
        try write("plugins/vercel/skills/workflow/SKILL.md", "---\nname: workflow\ndescription: Durable workflows\n---\n")
        try write("plugins/vercel/commands/deploy.md", "Deploy to Vercel\n")
        try write("plugins/off/commands/nope.md", "Nope\n")
        try write("home/.claude/plugins/installed_plugins.json", """
        {"version":2,"plugins":{"vercel@official":[{"scope":"user","installPath":"\(plugin)"}],
          "off@official":[{"scope":"user","installPath":"\(other)"}]}}
        """)
        try write("home/.claude/settings.json", #"{"enabledPlugins":{"vercel@official":true,"off@official":false}}"#)

        let cwd = root.appendingPathComponent("repo").path
        let commands = SlashCatalog.commands(for: .claude, cwd: cwd, homes: homes)
        let byName = Dictionary(commands.map { ($0.name, $0.about) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byName["ship"], "Project ship", "the project's skill wins over yours")
        XCTAssertEqual(byName["fix"], "Fix the build")
        XCTAssertEqual(byName["git:push"], "Push it")
        XCTAssertEqual(byName["vercel:workflow"], "(vercel) Durable workflows")
        XCTAssertEqual(byName["vercel:deploy"], "(vercel) Deploy to Vercel")
        XCTAssertNil(byName["hidden"])
        XCTAssertNil(byName["off:nope"])
        XCTAssertNotNil(byName["model"], "built-ins come too")
        XCTAssertEqual(commands.first?.name, SlashBuiltins.claude.first?.0)
    }

    func testProjectPluginOnlyInItsFolder() throws {
        let plugin = root.appendingPathComponent("plugins/p").path
        try write("plugins/p/commands/go.md", "Go\n")
        let project = root.appendingPathComponent("a").path
        try write("home/.claude/plugins/installed_plugins.json", """
        {"plugins":{"p@m":[{"scope":"project","projectPath":"\(project)","installPath":"\(plugin)"}]}}
        """)
        try write("home/.claude/settings.json", #"{"enabledPlugins":{"p@m":true}}"#)
        let inside = SlashCatalog.plugins(cwd: project + "/sub", homes: homes).map(\.name)
        let outside = SlashCatalog.plugins(cwd: root.appendingPathComponent("ab").path, homes: homes).map(\.name)
        XCTAssertEqual(inside, ["p:go"])
        XCTAssertEqual(outside, [])
    }

    func testFoldersStopAtRepoRootAndHome() throws {
        try write("home/work/repo/.git/HEAD", "")
        let deep = root.appendingPathComponent("home/work/repo/src/app").path
        let folders = SlashCatalog.folders(from: deep, homes: homes).map(\.lastPathComponent)
        XCTAssertEqual(folders, ["app", "src", "repo"])
        let loose = SlashCatalog.folders(from: root.appendingPathComponent("home/notes").path, homes: homes).map(\.lastPathComponent)
        XCTAssertEqual(loose, ["notes"], "never your home folder")
    }

    // MARK: Codex, Grok, agl

    func testCodexPromptsAreNamespaced() throws {
        try write("home/.codex/prompts/release.md", "---\ndescription: Cut a release\n---\n")
        let names = SlashCatalog.commands(for: .codex, cwd: "/tmp", homes: homes).map(\.name)
        XCTAssertTrue(names.contains("prompts:release"))
        XCTAssertTrue(names.contains("model"))
    }

    func testGrokReadsItsOwnAndClaudeSkills() throws {
        try write("home/.grok/skills/flint/SKILL.md", "---\nname: flint\ndescription: Mail\n---\n")
        try write("home/.claude/skills/ship/SKILL.md", "---\nname: ship\n---\n")
        try write("repo/.agents/skills/local/SKILL.md", "---\nname: local\n---\n")
        let names = SlashCatalog.commands(for: .grok, cwd: root.appendingPathComponent("repo").path, homes: homes).map(\.name)
        XCTAssertTrue(names.contains("flint"))
        XCTAssertTrue(names.contains("ship"))
        XCTAssertTrue(names.contains("local"))
    }

    func testAglHasOnlyItsBuiltIns() {
        let names = SlashCatalog.commands(for: .agl, cwd: "/tmp", homes: homes).map(\.name)
        XCTAssertEqual(names, ["models", "model", "clear", "help", "exit"])
    }
}
