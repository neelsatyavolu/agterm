import AgTermCore
import AppKit
import Combine

/// The saved appearance settings, observable by the Settings window and the main window.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published private(set) var appearance: AppearanceSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceSettings.load(from: defaults)
    }

    func update(_ change: (inout AppearanceSettings) -> Void) {
        var next = appearance
        change(&next)
        guard next != appearance else { return }
        appearance = next
        next.save(to: defaults)
    }
}

/// Full Disk Access status, re-checked whenever agterm comes back to the front
/// (e.g. after you flip the switch in System Settings).
final class DiskAccessMonitor: ObservableObject {
    static let shared = DiskAccessMonitor()

    @Published private(set) var status = DiskAccess.check()
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let next = DiskAccess.check()
        if next != status { status = next }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Opens the Full Disk Access pane and shows agterm in Finder so it can be dragged into the list.
    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
