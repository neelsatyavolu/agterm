import AgTermCore
import AppKit

/// Shown above the composer when the agent waits on you. With an approval prompt agterm can read,
/// a warn-tinted card with the question, what it's about, and one button per answer (each sends
/// the key the agent's prompt takes). Anything else (a picker, a menu), a dashed card with the
/// bottom of the screen as it is.
final class ChatPromptCard: NSView {
    enum Content: Equatable {
        case approval(PromptInfo, context: [String])
        case screen([String])
    }

    var onKey: (String) -> Void = { _ in }
    private(set) var content: Content?
    var isApproval: Bool {
        if case .approval = content { return true }
        return false
    }
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuilds the card only when what it shows changed.
    func show(_ content: Content?, force: Bool = false) {
        guard force || content != self.content else { return }
        self.content = content
        isHidden = content == nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch content {
        case .approval(let info, let context):
            context.forEach { stack.addArrangedSubview(label($0, Theme.fg2, ChatStyle.smallFont)) }
            if let question = info.question { stack.addArrangedSubview(label(question, Theme.fg, ChatStyle.boldFont)) }
            stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? stack)
            info.choices.forEach { stack.addArrangedSubview(button($0)) }
            stack.addArrangedSubview(button(PromptChoice(key: ChatInput.escape, label: "Esc  cancel", selected: false)))
        case .screen(let lines):
            lines.forEach { stack.addArrangedSubview(label($0, Theme.fg2, ChatStyle.smallFont)) }
            stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? stack)
            stack.addArrangedSubview(label("⌃` to answer in the terminal", Theme.fg3, ChatStyle.smallFont))
        case nil:
            break
        }
        needsDisplay = true
    }

    func applyAppearance() { show(content, force: true) }

    private func label(_ text: String, _ color: NSColor, _ font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func button(_ choice: PromptChoice) -> NSButton {
        let isEscape = choice.key == ChatInput.escape
        let title = NSMutableAttributedString(string: isEscape ? "" : "\(choice.key)  ",
                                              attributes: [.font: ChatStyle.font, .foregroundColor: Theme.warn])
        title.append(NSAttributedString(string: choice.label, attributes: [.font: choice.selected ? ChatStyle.boldFont : ChatStyle.font,
                                                                           .foregroundColor: isEscape ? Theme.fg3 : Theme.fg]))
        let button = ChoiceButton(title: "", target: self, action: #selector(choose(_:)))
        button.attributedTitle = title
        button.isBordered = false
        button.key = choice.key
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    @objc private func choose(_ sender: ChoiceButton) { onKey(sender.key) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        switch content {
        case .approval:
            Theme.warn.withAlphaComponent(0.08).setFill()
            path.fill()
            Theme.warn.withAlphaComponent(0.45).setStroke()
        case .screen:
            Theme.border.setStroke()
            path.setLineDash([4, 3], count: 2, phase: 0)
        case nil:
            return
        }
        path.lineWidth = 1
        path.stroke()
    }
}

private final class ChoiceButton: NSButton {
    var key = ""
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
