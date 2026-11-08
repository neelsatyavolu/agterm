import AgTermCore
import AppKit
import Combine
import SwiftUI

/// What the Usage window shows: the latest report and whether a scan is running.
final class UsageModel: ObservableObject {
    @Published var period: UsagePeriod = .week
    @Published private(set) var report: UsageReport = .empty
    @Published private(set) var scanning = false
    @Published private(set) var updatedAt: Date?
    private var appearance: AnyCancellable?

    init() {
        // `$appearance` fires before the window controller applies the theme; redraw just after.
        appearance = Preferences.shared.$appearance.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// Reads transcripts again and asks every login for its limits.
    func refresh() {
        scanning = true
        UsageScanner.shared.scan { [weak self] report in
            self?.report = report
            self?.updatedAt = Date()
            self?.scanning = false
        }
        UsageMonitor.shared.refreshAll()
    }
}

/// Window → Usage: tokens and estimated cost by day, model and project, and each login's limits.
final class UsageWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UsageWindowController()
    let model = UsageModel()
    private var appearance: AnyCancellable?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Usage"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 480)
        window.contentView = NSHostingView(rootView: UsageView(model: model, monitor: .shared))
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("agterm.usage")
        applyAppearance()
        appearance = Preferences.shared.$appearance.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Brings the window forward and refreshes what it shows.
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
    }

    func applyAppearance() {
        window?.appearance = Theme.appearance
        window?.backgroundColor = Theme.color(Theme.palette.bg)
    }
}
