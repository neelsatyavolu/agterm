import AgTermCore
import AppKit

/// Commit (⌥⌘C): a message the fast model drafts, then Commit, Commit & Push, or Commit, Push &
/// Open PR. With nothing to commit but commits not pushed, it offers Push and Push & Open PR.
final class CommitSheet: NSWindowController {
    /// Called once the steps finish, with what they made; the toolbar refreshes from it.
    var onDone: ((PublishOutcome) -> Void)?

    private let context: CommitContext
    private let scroll = NSTextView.scrollableTextView()
    // scrollableTextView's document view is always its text view.
    private var message: NSTextView { scroll.documentView as! NSTextView }
    private let placeholder = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var buttons: [(NSButton, PublishSteps)] = []
    private var cancel: NSButton?
    private var busy = false
    /// Branches the steps may run on: the one this opened on, and any a pull request made.
    private var branches: Set<String>

    private var commits: Bool { !context.changes.isEmpty }
    /// Off in self-tests, which mustn't run a model.
    static var draftsMessages = true

    init(context: CommitContext) {
        self.context = context
        branches = Set([context.branch].compactMap { $0 })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled, .docModalWindow],
                            backing: .buffered, defer: true)
        super.init(window: panel)
        build(panel)
        if commits, Self.draftsMessages { draftMessage() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func begin(for parent: NSWindow) {
        guard let sheet = window else { return }
        parent.beginSheet(sheet)
        sheet.makeFirstResponder(commits ? message : buttons.last?.0)
    }

    // MARK: Building

    private func build(_ panel: NSPanel) {
        let title = NSTextField(labelWithString: headline)
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let files = NSTextField(wrappingLabelWithString: fileSummary)
        files.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        files.textColor = .secondaryLabelColor
        files.maximumNumberOfLines = 4

        scroll.borderType = .bezelBorder
        message.isRichText = false
        message.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        message.textContainerInset = NSSize(width: 4, height: 6)
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.allowsUndo = true
        message.delegate = self
        placeholder.stringValue = "Describe the change"
        placeholder.textColor = .placeholderTextColor
        placeholder.font = message.font
        scroll.isHidden = !commits
        placeholder.isHidden = !commits

        status.font = NSFont.systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.stringValue = note
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        self.cancel = cancel
        row.addArrangedSubview(spinner)
        row.addView(cancel, in: .trailing)
        for (label, steps, tip) in choices {
            let button = NSButton(title: label, target: self, action: #selector(run(_:)))
            button.toolTip = tip
            button.tag = steps.rawValue
            row.addView(button, in: .trailing)
            buttons.append((button, steps))
        }
        buttons.last?.0.keyEquivalent = "\r"
        setBusy(false)

        let column = NSStackView(views: [title, files, scroll, status, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        scroll.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 110),
            files.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            status.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            row.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 10),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 7),
        ])
        panel.contentView = content
        panel.setContentSize(column.fittingSize)
    }

    private var headline: String {
        let branch = context.branch ?? "a detached HEAD"
        if commits { return "Commit \(context.changes.count) changed file\(context.changes.count == 1 ? "" : "s") on \(branch)" }
        let ahead = context.upstream.ahead
        if context.upstream.upstream == nil, context.branch != nil { return "Push \(branch), which isn't on the remote yet" }
        return ahead > 0 ? "Push \(ahead) commit\(ahead == 1 ? "" : "s") on \(branch)" : "Nothing to commit on \(branch)"
    }

    private var fileSummary: String {
        let shown = context.changes.prefix(6).map(Self.describe)
        let more = context.changes.count - shown.count
        return (shown + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n")
    }

    /// `git status --short` in words: "?? notes.txt" → "new       notes.txt".
    private static func describe(_ line: String) -> String {
        let code = line.prefix(2).trimmingCharacters(in: .whitespaces)
        let path = line.dropFirst(3)
        let word = switch code.first {
        case "?", "A": "new"
        case "D": "deleted"
        case "R": "renamed"
        default: "edited"
        }
        return word.padding(toLength: 9, withPad: " ", startingAt: 0) + path
    }

    /// What the sheet should warn about before anything runs.
    private var note: String {
        if GitRunner.ghPath == nil { return "Install the GitHub CLI (gh) to open pull requests from here." }
        if let pr = context.pullRequest, pr.isOpen { return "Pushing updates pull request #\(pr.number)." }
        if context.onDefaultBranch, let base = context.defaultBranch {
            return "You're on \(base). Opening a pull request first moves \(commits ? "this commit" : "these commits") to a new branch; \(base) stays as it is."
        }
        return commits ? "Everything is committed, including new files." : ""
    }

    private var choices: [(String, PublishSteps, String)] {
        let openPR = context.pullRequest?.isOpen == true
        if commits {
            return [("Commit", [.commit], "Commit only (no push)"),
                    ("Commit & Push", [.commit, .push], "Commit and push to \(context.upstream.upstream ?? "origin")")]
                + (openPR ? [] : [("Commit, Push & Open PR", [.commit, .push, .pullRequest],
                                   "Commit, push, then open a pull request with a written title and description")])
        }
        return [("Push", [.push], "Push to \(context.upstream.upstream ?? "origin")")]
            + (openPR ? [] : [("Push & Open PR", [.push, .pullRequest], "Push, then open a pull request")])
    }

    // MARK: Drafting

    private func draftMessage() {
        placeholder.stringValue = "Writing a message…"
        spinner.startAnimation(nil)
        let request = GitPublish.commitRequest(stat: context.stat, patch: context.patch, recentSubjects: context.recentSubjects)
        QuickCommandRunner.shared.ask(system: GitPublish.commitInstructions, message: request) { [weak self] result in
            guard let self, !self.busy else { return }
            self.spinner.stopAnimation(nil)
            self.placeholder.stringValue = "Describe the change"
            // Don't replace anything you started typing meanwhile.
            guard self.message.string.isEmpty, case let .success(reply) = result, let text = GitPublish.cleanMessage(reply) else {
                self.updatePlaceholder()
                return
            }
            self.message.string = text
            self.message.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
            self.updatePlaceholder()
        }
    }

    fileprivate func updatePlaceholder() { placeholder.isHidden = !commits || !message.string.isEmpty }

    // MARK: Running

    @objc private func run(_ sender: NSButton) {
        let steps = PublishSteps(rawValue: sender.tag)
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if steps.contains(.commit), text.isEmpty {
            status.stringValue = "Write a commit message first."
            status.textColor = Theme.danger
            return
        }
        setBusy(true)
        let context = context, branches = branches
        GitRunner.writes.async { [weak self] in
            let result = GitActions.publish(steps, message: text, context: context, branches: branches,
                                            onBranch: { [weak self] made in self?.branches.insert(made) }) { [weak self] step in
                self?.status.stringValue = step
                self?.status.textColor = .secondaryLabelColor
            }
            DispatchQueue.main.async { [weak self] in self?.finish(result) }
        }
    }

    private func finish(_ result: Result<PublishOutcome, GitFailure>) {
        setBusy(false)
        switch result {
        case let .success(outcome):
            if let url = outcome.pullRequest.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(url) }
            onDone?(outcome)
            close()
        case let .failure(failure):
            status.stringValue = failure.message
            status.textColor = Theme.danger
        }
    }

    private func setBusy(_ on: Bool) {
        busy = on
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        for (button, steps) in buttons { button.isEnabled = !on && (!steps.contains(.pullRequest) || GitRunner.ghPath != nil) }
        cancel?.isEnabled = !on
        message.isEditable = !on
    }

    @objc private func cancelSheet() { close() }

    var buttonTitlesForTest: [String] { buttons.map(\.0.title) }

    override func close() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        super.close()
    }
}

extension CommitSheet: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { updatePlaceholder() }
}
