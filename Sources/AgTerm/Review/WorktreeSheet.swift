import AgTermCore
import AppKit

/// New Worktree Tab (⇧⌘N): a branch name, the agent to start and, optionally, its first task.
final class WorktreeSheet: NSWindowController {
    /// The worktree is made; open a tab in `path` typing `command` (nil: just a shell).
    var onCreate: ((_ path: String, _ command: String?) -> Void)?

    private let cwd: String
    private let branchField = NSTextField()
    private let agentPopup = NSPopUpButton()
    private let taskField = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let create = NSButton(title: "Create", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    /// Popup entries: an agent id, or nil for a plain shell.
    private var agents: [String?] = []

    /// `installed`: the agents found on PATH that take a first task (looked up off the main thread).
    init(cwd: String, currentBranch: String?, currentAgent: String?, installed: [String]) {
        self.cwd = cwd
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled, .docModalWindow],
                            backing: .buffered, defer: true)
        super.init(window: panel)
        build(panel, currentBranch: currentBranch, currentAgent: currentAgent, installed: installed)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func begin(for parent: NSWindow) {
        guard let sheet = window else { return }
        parent.beginSheet(sheet)
        sheet.makeFirstResponder(branchField)
    }

    private func build(_ panel: NSPanel, currentBranch: String?, currentAgent: String?, installed: [String]) {
        let title = NSTextField(labelWithString: "New worktree tab")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "A new branch from \(currentBranch ?? "the current commit") in a folder of its own, so this agent's edits never touch your other tabs. Your .env files are copied in.")
        intro.textColor = .secondaryLabelColor
        intro.font = NSFont.systemFont(ofSize: 11.5)

        branchField.stringValue = WorktreeNames.suggested(seed: UInt64.random(in: 0...UInt64.max))
        branchField.placeholderString = "agterm/my-change"
        branchField.toolTip = "The branch to make (or check out, if it exists)"

        var ids: [String] = [AgentIntegration.launchAgent.id] + installed
        if let currentAgent { ids.insert(currentAgent, at: 0) }
        agents = ids.reduce(into: [String?]()) { list, id in if !list.contains(id) { list.append(id) } } + [nil]
        for id in agents {
            agentPopup.addItem(withTitle: id.map { AgentKind.named($0)?.title ?? $0 } ?? "Just a shell")
        }
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        agentPopup.toolTip = "What to start in the new tab"
        taskField.placeholderString = "Task for the agent (optional)"
        taskField.toolTip = "Sent as the agent's first message"

        status.font = NSFont.systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        if FileManager.default.fileExists(atPath: cwd + "/" + WorktreeActions.setupScript) {
            status.stringValue = "\(WorktreeActions.setupScript) runs first in the new tab."
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        cancel.target = self
        cancel.action = #selector(cancelSheet)
        cancel.keyEquivalent = "\u{1b}"
        create.target = self
        create.action = #selector(make)
        create.keyEquivalent = "\r"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Branch"), branchField],
            [NSTextField(labelWithString: "Start"), agentPopup],
            [NSTextField(labelWithString: "Task"), taskField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        let row = NSStackView()
        row.orientation = .horizontal
        row.addArrangedSubview(spinner)
        row.addView(cancel, in: .trailing)
        row.addView(create, in: .trailing)

        let column = NSStackView(views: [title, intro, grid, status, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 440),
            grid.widthAnchor.constraint(equalTo: intro.widthAnchor),
            branchField.widthAnchor.constraint(equalToConstant: 360),
            status.widthAnchor.constraint(equalTo: intro.widthAnchor),
            row.widthAnchor.constraint(equalTo: intro.widthAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(column.fittingSize)
        agentChanged()
    }

    private var selectedAgent: String? { agents.indices.contains(agentPopup.indexOfSelectedItem) ? agents[agentPopup.indexOfSelectedItem] : nil }

    /// Only agents that take a first message on the command line get the task field.
    @objc private func agentChanged() {
        taskField.isEnabled = selectedAgent.flatMap(HandoffTarget.init(rawValue:)) != nil
    }

    @objc private func make() {
        let branch = WorktreeNames.branch(branchField.stringValue)
        guard !branch.isEmpty else {
            status.stringValue = "Type a branch name."
            status.textColor = Theme.danger
            return
        }
        branchField.stringValue = branch
        let agent = selectedAgent
        let task = taskField.isEnabled ? taskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        [create, cancel, branchField, agentPopup, taskField].forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        status.stringValue = "Making \(branch)…"
        status.textColor = .secondaryLabelColor
        let cwd = cwd
        GitRunner.writes.async { [weak self] in
            let result = WorktreeActions.create(cwd: cwd, branch: branch)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                switch result {
                case let .success(made):
                    self.close()
                    self.onCreate?(made.path, Self.command(agent: agent, task: task, setup: made.hasSetupScript))
                case let .failure(failure):
                    self.status.stringValue = failure.message
                    self.status.textColor = Theme.danger
                    [self.create, self.cancel, self.branchField, self.agentPopup].forEach { $0.isEnabled = true }
                    self.agentChanged()
                }
            }
        }
    }

    /// The setup script (if the repo has one), then the agent with its first task.
    static func command(agent: String?, task: String, setup: Bool) -> String? {
        let start = agent.map { id in
            task.isEmpty ? (AgentKind.named(id)?.command ?? id) : HandoffTarget(rawValue: id)?.commandLine(prompt: task) ?? id
        }
        let parts = [setup ? "sh \(WorktreeActions.setupScript)" : nil, start].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    @objc private func cancelSheet() { close() }

    override func close() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        super.close()
    }
}
