import AgTermCore
import AppKit
import SwiftUI

/// "Welcome to agterm 1.2": a window shown once after updating to 1.2 from an earlier version,
/// in place of the What's New tab, with what was added since 1.1.7 and a switch or button for
/// each new thing that has a setting. Also in the agterm menu.
enum Welcome {
    static let milestone = "1.2.0"
    static let since = "1.1.7"

    /// What a row offers besides its text.
    enum Control {
        case none
        /// Its menu shortcut, shown as a hint.
        case shortcut(String)
        /// A hint without a shortcut ("Right-click a tab").
        case hint(String)
        /// A UserDefaults switch; `changed` runs after it flips.
        case toggle(key: String, defaultOn: Bool, changed: () -> Void)
        /// A button.
        case button(String, () -> Void)
    }

    struct Feature: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        let control: Control
        var id: String { title }
    }

    struct Group: Identifiable {
        let title: String
        let features: [Feature]
        var id: String { title }
    }

    static var groups: [Group] {
        [
            Group(title: "New in 1.2", features: [
                Feature(symbol: "desktopcomputer", title: "Run heavy work on your other Macs",
                        detail: "Pair another Mac and agents send builds, test suites and renders there with agterm-remote. The project is copied over, output streams back into the tab.",
                        control: .button("Set Up…") { SettingsWindowController.shared.show(pane: "Macs") }),
                Feature(symbol: "cpu", title: "agl, the local-model agent",
                        detail: "With agl on your PATH, start it like any other agent, read it in Chat and on your phone, and get it back after a relaunch.",
                        control: .none),
            ]),
            Group(title: "Agents", features: [
                Feature(symbol: "bubble.left.and.bubble.right", title: "Chat view",
                        detail: "Read a Claude Code, Codex, Grok or agl tab as a conversation, with diffs and command results, and reply from the box at the bottom.",
                        control: .shortcut("⌃`")),
                Feature(symbol: "point.3.connected.trianglepath.dotted", title: "Agents coordinate",
                        detail: "Agents see every other agent in agterm, ask each other about their work and leave messages before they edit the same repo. Project memory now works for OpenCode, Kilo, Cursor and Amp too.",
                        control: .toggle(key: AgentIntegration.consultKey, defaultOn: true) { AgentIntegration.installShellIntegration() }),
                Feature(symbol: "cup.and.saucer", title: "Keep Mac awake while agents run",
                        detail: "Your Mac doesn't sleep on its own while an agent is working. Settings → Agents can keep it awake with the lid closed too.",
                        control: .toggle(key: KeepAwake.enabledKey, defaultOn: false) {}),
                Feature(symbol: "magnifyingglass", title: "Search conversations",
                        detail: "Find any past Claude Code, Codex or Grok conversation by what was said, and reopen it in a new tab.",
                        control: .shortcut("⇧⌘F")),
                Feature(symbol: "list.bullet.rectangle", title: "Session Timeline",
                        detail: "Every prompt in the tab with its status; click one to jump to where that turn starts.",
                        control: .shortcut("⇧⌘L")),
                Feature(symbol: "arrow.triangle.swap", title: "Hand off",
                        detail: "Continue a conversation in Claude Code, Codex, Grok or Gemini CLI, in a new tab beside it.",
                        control: .hint("Top right of the window")),
            ]),
            Group(title: "Review and ship", features: [
                Feature(symbol: "doc.text.magnifyingglass", title: "Show Changes",
                        detail: "Every changed file and its diff beside the terminal: what the agent changed, what's uncommitted, or the whole branch.",
                        control: .shortcut("⇧⌘E")),
                Feature(symbol: "arrow.up.circle", title: "Commit and pull request",
                        detail: "A drafted commit message, then commit, push and open a pull request with a written description in one step.",
                        control: .shortcut("⌥⌘C")),
                Feature(symbol: "square.split.2x1", title: "Worktree tabs",
                        detail: "Start an agent on a new branch in a folder of its own, with your .env files copied in.",
                        control: .shortcut("⇧⌘N")),
                Feature(symbol: "chart.bar", title: "Usage",
                        detail: "Tokens and estimated cost by day, model and project, and how much of each login's limits is left.",
                        control: .shortcut("⇧⌘U")),
            ]),
            Group(title: "Tabs and team", features: [
                Feature(symbol: "pin", title: "Pin tabs",
                        detail: "Pinned tabs stay at the top of the sidebar, through drags, new tabs and relaunches.",
                        control: .hint("Right-click a tab")),
                Feature(symbol: "command", title: "Command palette",
                        detail: "Type a few letters of any menu command or open tab and press Return.",
                        control: .shortcut("⇧⌘P")),
                Feature(symbol: "person.3", title: "Team Dashboard",
                        detail: "Your agterm Teams team's usage, spend, members and shared logins, without agmux.",
                        control: .button("Open") { MainActor.assumeIsolated { TeamsWindowController.shared.show() } }),
                Feature(symbol: "chart.line.uptrend.xyaxis", title: "Anonymous usage counts",
                        detail: "A random ID, versions, which agents start and how often features are used. Never files, commands, what you type or account details.",
                        control: .toggle(key: Analytics.enabledKey, defaultOn: true) {}),
            ]),
        ]
    }

    /// Shows the window when this launch is the first since updating past 1.2. True if it did,
    /// so What's New doesn't open its tab too.
    static func showIfCrossed(lastSeen: String?, current: String, in controller: MainWindowController) -> Bool {
        guard Changelog.crossed(milestone, lastSeen: lastSeen, current: current) else { return false }
        WelcomeWindowController.shared.show(over: controller)
        return true
    }
}

/// The welcome window, reused. Built in the current theme each time it opens.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    private weak var mainController: MainWindowController?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = "Welcome to agterm 1.2"
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(over controller: MainWindowController?) {
        mainController = controller ?? mainController
        guard let window else { return }
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.color(Theme.palette.bg)
        window.contentViewController = NSHostingController(rootView: WelcomeView(
            showChangelog: { [weak self] in self?.showChangelog() },
            done: { [weak self] in self?.close() }))
        window.setContentSize(NSSize(width: 640, height: 680))
        if let parent = controller?.window ?? mainController?.window {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - 320, y: frame.midY - 340))
        } else {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func showChangelog() {
        close()
        guard let controller = mainController else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        WhatsNew.showAll(in: controller)
    }
}
