import AgTermCore
import AppKit

/// The What's New tab: the changelog played into a new shell tab after an update, or from
/// the agterm menu.
enum WhatsNew {
    /// The version whose changes were last shown (or that was first installed).
    static let lastSeenKey = "whatsNewLastSeenVersion"
    private static let updateNote = "what changed since your last version"
    private static let notFound = "\u{1B}[2mThe changelog wasn't found.\u{1B}[0m"

    /// After an update, shows the releases since the last version seen, then remembers this one.
    /// Builds without a version (`swift build`) never show it on their own.
    static func showIfUpdated(in controller: MainWindowController) {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        let defaults = UserDefaults.standard
        let unseen = Changelog.unseen(releases() ?? [], lastSeen: defaults.string(forKey: lastSeenKey), current: current)
        defaults.set(current, forKey: lastSeenKey)
        guard !unseen.isEmpty else { return }
        controller.showWhatsNew { ChangelogRender.lines(unseen, columns: $0, note: updateNote) }
    }

    /// Every release, from the menu.
    static func showAll(in controller: MainWindowController) {
        controller.showWhatsNew(allLines())
    }

    /// Lines for every release at a given width, or one dim line when there is no changelog.
    static func allLines() -> (Int) -> [String] {
        guard let releases = releases(), !releases.isEmpty else { return { _ in [notFound] } }
        return { ChangelogRender.lines(releases, columns: $0) }
    }

    private static func releases() -> [Release]? {
        guard let url = changelogURL(), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Changelog.parse(text)
    }

    private static func changelogURL() -> URL? {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") { return url }
        #if DEBUG
        // `.build/debug/AgTerm` has no app bundle; read the repo's copy.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("CHANGELOG.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }
}

/// Feeds lines into a new tab one at a time, holding the shell's first output so its prompt
/// lands below them. Any keystroke shows the rest at once.
final class WhatsNewReveal {
    private static let interval: TimeInterval = 0.018
    private let view: AgentTerminalView
    private var pending: ArraySlice<String>
    private let previousOnInput: (([UInt8]) -> Void)?
    private var timer: Timer?

    /// Call in the same run loop turn that started the tab's shell, before its output arrives.
    /// A blank line separates the lines from the prompt.
    static func play(_ lines: [String], in view: AgentTerminalView) {
        WhatsNewReveal(lines + [""], view: view).start()
    }

    private init(_ lines: [String], view: AgentTerminalView) {
        self.view = view
        pending = lines[...]
        previousOnInput = view.onInput
    }

    /// The timer keeps this object alive until the reveal ends.
    private func start() {
        view.holdOutput()
        let previous = previousOnInput
        view.onInput = { [weak self] bytes in
            self?.finish()
            previous?(bytes)
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [self] _ in step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let line = pending.popFirst() else { return finish() }
        view.feed(text: line + "\r\n")
    }

    private func finish() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        if !pending.isEmpty { view.feed(text: pending.joined(separator: "\r\n") + "\r\n") }
        pending = []
        view.onInput = previousOnInput
        view.releaseOutput()
    }
}
