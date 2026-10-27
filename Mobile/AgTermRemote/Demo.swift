import AgTermCore
import Foundation

/// Sample tabs for Try the Demo, so the app can be explored without a Mac (App Review can't pair
/// one). Everything here is made up and stays on the phone.
enum Demo {
    static let macName = "agterm on Demo Mac"
    static let approvalTab = "demo-checkout"

    static let options = NewTabOptions(
        agents: [.init(id: "claude", title: "Claude Code"), .init(id: "codex", title: "Codex")],
        folders: ["~/code/shop-api", "~/code/web"], home: "~")

    static var tabs: [RemoteTabRow] {
        [
            row(approvalTab, "Fix the flaky checkout test", .waiting, agent: "claude", folder: "shop-api",
                branch: "fix/checkout-retry", added: 24, removed: 9,
                prompt: PromptInfo(question: "Allow this edit to tests/checkout.test.ts?", choices: [
                    PromptChoice(key: "1", label: "Yes", selected: true),
                    PromptChoice(key: "2", label: "Yes, and don't ask again this session", selected: false),
                    PromptChoice(key: "3", label: "No, and tell the agent what to do differently", selected: false),
                ])),
            row("demo-dark-mode", "Add dark mode to settings", .working, agent: "codex", folder: "web",
                branch: "feat/dark-mode", added: 112, removed: 31),
            row("demo-deps", "Update dependencies", .done, agent: "claude", folder: "shop-api",
                branch: "main", added: 8, removed: 8),
            row("demo-shell", "zsh", .idle, agent: nil, folder: "~", branch: nil),
        ]
    }

    static func row(_ id: String, _ title: String, _ status: TabStatus, agent: String?, folder: String,
                    branch: String?, added: Int? = nil, removed: Int? = nil, prompt: PromptInfo? = nil) -> RemoteTabRow {
        RemoteTabRow(id: id, title: title, provider: agent ?? AgTermWire.shellProvider, projectName: folder,
                     processing: status == .working, unread: false, needsApproval: status == .waiting,
                     lastActive: ISO8601DateFormatter().string(from: Date()), status: status.wireName, model: nil,
                     linesAdded: added, linesRemoved: removed,
                     agterm: TabInfo(status: status, agent: agent, folder: folder, branch: branch, prompt: prompt))
    }

    // MARK: Screens

    /// ANSI palette indexes, drawn in the Mac theme's colors.
    private static let dim = 8, green = 2, red = 1, blue = 4, yellow = 3

    static var screens: [String: ScreenSnapshot] {
        [
            approvalTab: screen([
                [run("~/code/shop-api on fix/checkout-retry", dim)],
                [],
                [run("> ", blue), run("Run the checkout tests 20 times and tell me which ones fail.")],
                [],
                [run("● ", green), run("Run npm test -- checkout --repeat 20")],
                [run("  PASS ", green), run("tests/cart.test.ts (20/20)")],
                [run("  PASS ", green), run("tests/payment.test.ts (20/20)")],
                [run("  FAIL ", red), run("tests/checkout.test.ts (18/20)")],
                [run("       ✕ retries a declined card once", red)],
                [],
                [run("Two of twenty runs of checkout.test.ts failed, both in \"retries a")],
                [run("declined card once\". Everything else passed every run.")],
                [],
                [run("> ", blue), run("The checkout test fails about one run in ten. Find out why and fix it.")],
                [],
                [run("● ", green), run("Read tests/checkout.test.ts")],
                [run("● ", green), run("Read src/checkout/retry.ts")],
                [],
                [run("The test waits a fixed 50 ms for the retry, but the retry backs off")],
                [run("with jitter, so it sometimes lands later. I'll wait for the retry event.")],
                [],
                [run("● ", yellow), run("Edit tests/checkout.test.ts")],
                [run("  41 ", dim), run("-  await sleep(50)", red)],
                [run("  41 ", dim), run("+  await once(cart, 'retried')", green)],
                [],
            ]),
            "demo-dark-mode": screen([
                [run("~/code/web on feat/dark-mode", dim)],
                [],
                [run("> ", blue), run("Where do the app's colors come from?")],
                [],
                [run("● ", green), run("Search \"--color\" in src")],
                [run("● ", green), run("Read src/theme/tokens.css")],
                [],
                [run("Every color is a CSS variable in src/theme/tokens.css, 38 of them.")],
                [run("Components use the variables; nothing hard-codes a color except two")],
                [run("SVG icons in src/icons/, which use currentColor already.")],
                [],
                [run("> ", blue), run("Add a dark mode switch to the settings page.")],
                [],
                [run("● ", green), run("Read src/settings/SettingsPage.tsx")],
                [run("● ", green), run("Edit src/theme/tokens.css  +64 −12")],
                [run("● ", green), run("Edit src/settings/SettingsPage.tsx  +48 −19")],
                [run("● ", yellow), run("Run npm test -- settings")],
                [run("  PASS ", green), run("src/settings/SettingsPage.test.tsx (12 tests)")],
                [run("  …", dim)],
            ]),
            "demo-deps": screen([
                [run("~/code/shop-api on main", dim)],
                [],
                [run("> ", blue), run("Update the dependencies and make sure the tests still pass.")],
                [],
                [run("● ", green), run("Run npm outdated")],
                [run("● ", green), run("Edit package.json  +8 −8")],
                [run("● ", green), run("Run npm test")],
                [run("  Tests: 214 passed, 214 total", green)],
                [],
                [run("Updated eight packages; all 214 tests pass. Nothing needed code changes.")],
            ]),
            "demo-shell": shell,
        ]
    }

    static var shell: ScreenSnapshot {
        screen([[run("~ ", blue), run("$ ")]])
    }

    static func screen(_ lines: [[ScreenRun]]) -> ScreenSnapshot {
        ScreenSnapshot(cols: 72, rows: max(lines.count, 1), lines: lines, cursorRow: nil, cursorCol: nil,
                       theme: ThemeCatalog.defaultID)
    }

    static func run(_ text: String, _ color: Int? = nil) -> ScreenRun { ScreenRun(t: text, f: color) }

    // MARK: Conversations

    static var timelines: [String: [MobileTimelineEntry]] {
        [
            approvalTab: [
                user("The checkout test fails about one run in ten. Find out why and fix it."),
                tool("Read", "tests/checkout.test.ts"),
                tool("Read", "src/checkout/retry.ts"),
                assistant("The test waits a fixed 50 ms for the retry, but the retry backs off with jitter, so it sometimes lands later. I'll wait for the retry event instead."),
                tool("Edit", "tests/checkout.test.ts", status: "running", added: 1, removed: 1),
            ],
            "demo-dark-mode": [
                user("Add a dark mode switch to the settings page."),
                tool("Read", "src/settings/SettingsPage.tsx"),
                tool("Edit", "src/theme/tokens.css", added: 64, removed: 12),
                tool("Edit", "src/settings/SettingsPage.tsx", added: 48, removed: 19),
                tool("Run", "npm test -- settings", status: "running"),
            ],
            "demo-deps": [
                user("Update the dependencies and make sure the tests still pass."),
                tool("Run", "npm outdated"),
                tool("Edit", "package.json", added: 8, removed: 8),
                tool("Run", "npm test"),
                assistant("Updated eight packages; all **214 tests pass**. Nothing needed code changes."),
            ],
        ]
    }

    static func user(_ text: String) -> MobileTimelineEntry { entry("user", text: text) }
    static func assistant(_ text: String) -> MobileTimelineEntry { entry("assistant", text: text) }

    static func tool(_ lead: String, _ subject: String, status: String = "done",
                     added: Int? = nil, removed: Int? = nil) -> MobileTimelineEntry {
        MobileTimelineEntry(id: UUID().uuidString, kind: "tool", lead: lead, subject: subject, status: status,
                            additions: added, deletions: removed, ts: now)
    }

    private static func entry(_ kind: String, text: String) -> MobileTimelineEntry {
        MobileTimelineEntry(id: UUID().uuidString, kind: kind, text: text, ts: now)
    }

    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// What the demo agent says back to a reply.
    static let answer = "This is the demo, so no agent is running. Paired with agterm on your Mac, your reply goes to the agent in this tab and its answer shows up here and on the screen."
}
