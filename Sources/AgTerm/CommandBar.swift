import AgTermCore
import AppKit

/// ⌘K: describe what you want, a small fast model writes the shell command, ⏎ puts it at your
/// prompt to check before running (⌘⏎ runs it). Opens under the line you're typing on, like Cursor's.
final class CommandBar: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 640

    /// Called with the command and whether to run it; the bar closes itself after.
    var onInsert: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    /// What the model gets besides your request: folder, shell and the tab's recent commands and output.
    var context: (() -> (cwd: String, shell: String, output: String))?

    private let field = NSTextField()
    private let modelLabel = NSTextField(labelWithString: "")
    private let result = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var command: String?
    private var running: QuickCommandRunner.Run?
    /// Bumped on every request so a late reply to an old one is ignored.
    private var generation = 0
    private var resultConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // Long commands wrap so you can read all of what you'd run.
        result.lineBreakMode = .byCharWrapping
        result.maximumNumberOfLines = 4
        result.cell?.wraps = true
        result.cell?.truncatesLastVisibleLine = true
        result.isSelectable = true
        for label in [modelLabel, hint] { label.font = Theme.metaFont }
        for view in [field, modelLabel, result, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        modelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The request, the command it wrote (once there is one), then keys on the left and the model on the right.
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            result.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            result.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            result.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: modelLabel.leadingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            modelLabel.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            modelLabel.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
        ])
        compactConstraints = [hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8)]
        resultConstraints = [hint.topAnchor.constraint(equalTo: result.bottomAnchor, constant: 10)]
        showResult(nil, isError: false)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        if result.preferredMaxLayoutWidth != result.frame.width {
            result.preferredMaxLayoutWidth = result.frame.width
            needsLayout = true
        }
    }

    func refreshAppearance() {
        layer?.backgroundColor = Theme.color(Theme.palette.chrome).cgColor
        layer?.borderColor = Theme.border.cgColor
        field.textColor = Theme.fg
        field.placeholderAttributedString = NSAttributedString(string: "Describe a command", attributes: [
            .foregroundColor: Theme.fg3, .font: NSFont.systemFont(ofSize: 14),
        ])
        modelLabel.textColor = Theme.fg3
        hint.textColor = Theme.fg3
        result.font = Theme.terminalFont(family: Theme.settings.fontFamily, size: 13)
    }

    /// Opens empty, ready to type.
    func begin() {
        cancelRun()
        field.stringValue = ""
        showResult(nil, isError: false)
        modelLabel.stringValue = QuickCommandRunner.shared.currentModelName
        window?.makeFirstResponder(field)
    }

    func focus() { window?.makeFirstResponder(field) }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit(run: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// ⌘⏎ isn't a text-editing command, so it arrives as a key equivalent.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76, window?.firstResponder === field.currentEditor() {
            submit(run: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func controlTextDidChange(_ obj: Notification) {
        // A new request: the command shown no longer answers it.
        if command != nil || running != nil {
            cancelRun()
            showResult(nil, isError: false)
        }
    }

    #if DEBUG
    /// For the self-test: type a request and press ⏎ (once to ask, again to insert).
    func selfTestSubmit(_ text: String?) {
        if let text { field.stringValue = text }
        submit(run: false)
    }
    var selfTestResult: String { result.stringValue }
    #endif

    private func submit(run: Bool) {
        if let command {
            onInsert?(command, run)
            return close()
        }
        let request = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, running == nil else { return }
        let context = context?() ?? (cwd: NSHomeDirectory(), shell: "zsh", output: "")
        generation += 1
        let current = generation
        modelLabel.stringValue = QuickCommandRunner.shared.currentModelName + "…"
        showResult("Writing a command…", isError: false, pending: true)
        running = QuickCommandRunner.shared.generate(request: request, cwd: context.cwd, shell: context.shell, output: context.output) { [weak self] model, outcome in
            guard let self, current == self.generation else { return }
            self.running = nil
            self.modelLabel.stringValue = model?.shortName ?? ""
            switch outcome {
            case let .success(command):
                self.command = command
                self.showResult(command, isError: false)
            case let .failure(failure):
                self.showResult(failure.message, isError: true)
            }
        }
    }

    private func close() {
        cancelRun()
        onClose?()
    }

    /// Stops a request in flight; called whenever the bar goes away.
    func cancelRun() {
        generation += 1
        running?.cancel()
        running = nil
        command = nil
    }

    private func showResult(_ text: String?, isError: Bool, pending: Bool = false) {
        let visible = text != nil
        result.isHidden = !visible
        hint.stringValue = visible && !isError && !pending ? "⏎ insert   ⌘⏎ run   esc close" : "⏎ write   esc close"
        result.stringValue = text ?? ""
        result.textColor = isError ? Theme.danger : pending ? Theme.fg3 : Theme.fg
        NSLayoutConstraint.deactivate(visible ? compactConstraints : resultConstraints)
        NSLayoutConstraint.activate(visible ? resultConstraints : compactConstraints)
    }
}

extension QuickCommandRunner {
    /// For the bar's corner; empty until the CLIs have been found.
    var currentModelName: String { isReady ? currentModel()?.shortName ?? "" : "" }
}
