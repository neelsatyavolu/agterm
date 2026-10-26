import AgTermCore
import SwiftUI

// MARK: Agents

struct AgentsPane: View {
    @AppStorage(AgentIntegration.launchAgentKey) private var launchAgent = AgentKind.claude.id
    @AppStorage(AgentIntegration.memoryKey) private var memory = true
    @AppStorage(AgentIntegration.consultKey) private var consult = true
    /// Found off the main thread, since it may wait on your shell's startup files.
    @State private var installed: [AgentKind]?

    /// Checked once when Settings opens.
    private static let mcpStatus: String = {
        let base = "claude and codex started in agterm get these MCP servers, the same ones agmux gives its agents. "
            + "With agmux installed they're agmux's own, and memory is shared with agmux for the folders it knows. "
            + "Without agmux, agterm's copies give every git repo its own memory. "
            + "Servers you already configured aren't added twice. Start an agent with AGTERM_MCP=0 to skip them once."
        guard AgentIntegration.mcpBundles() != nil else {
            return "agterm's copies of the servers are missing (a development build?). " + base
        }
        guard AgentIntegration.findOnPath("node", excluding: nil) != nil else {
            return "Node.js wasn't found on agterm's PATH; agents' own shells may still find it. " + base
        }
        return base
    }()

    private static let supported = AgentKind.all.map(\.title).joined(separator: ", ")

    var body: some View {
        Form {
            Section {
                Picker("⌥⌘T starts", selection: $launchAgent) {
                    ForEach(installed ?? AgentKind.all, id: \.self) { Text($0.title).tag($0.id) }
                }
            } header: {
                Text("New agent tab")
            } footer: {
                Footnote("Opens a tab in the current folder and starts the agent there. ⌥⌘1, ⌥⌘2 and ⌥⌘3 start "
                         + "Claude Code, Codex and Grok; Shell → New Tab With Agent and right-clicking + list every agent "
                         + "you have installed. When the agent quits, the shell stays.\n\n"
                         + "Tabs show status, \"needs you\" and lines changed for \(Self.supported).")
            }

            Section {
                Toggle("agmux project memory", isOn: $memory)
                Toggle("consult", isOn: $consult)
            } header: {
                Text("MCP servers")
            } footer: {
                Footnote(Self.mcpStatus)
            }
        }
        .task { installed = await AgentsPane.findInstalled() }
    }

    static func findInstalled() async -> [AgentKind]? {
        await Task.detached { () -> [AgentKind]? in
            _ = QuickCommandRunner.shared.installed()
            return AgentIntegration.installedAgents()
        }.value
    }
}

// MARK: Permissions

struct PermissionsPane: View {
    @State private var installed: [AgentKind]?

    var body: some View {
        Form {
            Section {
                let skippable = (installed ?? [.claude, .codex, .grok]).filter { $0.bypassFlags != nil }
                ForEach(skippable, id: \.self) { BypassToggle(agent: $0) }
            } header: {
                Text("Skip permission prompts")
            } footer: {
                Footnote("Agents you start in agterm run commands and edit files without asking first. Codex's flag also "
                         + "turns off its sandbox. Runs where you pass a permission flag yourself are left as they are. "
                         + "Installed agents with no such flag aren't listed.")
            }
        }
        .task { installed = await AgentsPane.findInstalled() }
    }
}

/// One agent's "skip permission prompts" switch, with the flag it adds.
private struct BypassToggle: View {
    let agent: AgentKind
    @AppStorage private var on: Bool

    init(agent: AgentKind) {
        self.agent = agent
        _on = AppStorage(wrappedValue: false, AgentIntegration.bypassKey(agent))
    }

    var body: some View {
        Toggle(isOn: $on) {
            HStack(spacing: 8) {
                Text(agent.title)
                Text((agent.bypassFlags ?? []).joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // Agents other than Claude Code and Codex only get a wrapper while this is on.
        .onChange(of: on) { _, _ in AgentIntegration.installShellIntegration() }
    }
}

// MARK: Command (⌘K)

struct CommandPane: View {
    @AppStorage(QuickCommandRunner.modelKey) private var model = "auto"
    /// Found off the main thread, since it may wait on your shell's startup files.
    @State private var installed: Set<QuickModel>?

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $model) {
                    Text(automaticLabel).tag("auto")
                    Divider()
                    ForEach(QuickModel.allCases, id: \.self) { option in
                        Text(label(option)).tag(option.rawValue)
                    }
                }
            } header: {
                Text("⌘K writes a command")
            } footer: {
                Footnote("Press ⌘K in a tab and describe what you want. ⏎ puts the command at your prompt so you can "
                         + "check it; ⌘⏎ runs it. agterm asks through the CLI you're already signed in to, using its fastest "
                         + "setting: Claude Haiku (about 2.5 s), Codex Luna at low effort (about 4 s) or Grok at low effort "
                         + "(about 5 s). Automatic uses the first one installed, in that order.\n\n"
                         + "The model gets your request, the tab's folder, your shell and the last \(QuickCommand.screenLines) "
                         + "lines on screen. It has no tools, so it can't read files or run anything, and the "
                         + "conversation isn't kept in the CLI's history.")
            }
        }
        .task {
            let found = await Task.detached { QuickCommandRunner.shared.installed() }.value
            installed = found
        }
    }

    private var automaticLabel: String {
        guard let installed else { return "Automatic" }
        guard let pick = QuickCommand.pick(preferred: nil, installed: installed) else { return "Automatic (none installed)" }
        return "Automatic (\(pick.title))"
    }

    private func label(_ option: QuickModel) -> String {
        guard let installed, !installed.contains(option) else { return option.title }
        return option.title + " (not installed)"
    }
}

// MARK: Teams & Phone

struct ConnectionsPane: View {
    var body: some View {
        Form {
            TeamsSection(account: .shared)
            PhoneSection(remote: .shared)
        }
    }
}
