import AgTermCore
import AppKit
import SwiftUI

/// ⌘, — one window, reused, with a toolbar of panes like the Mac's own apps.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.add("General", symbol: "gearshape", GeneralPane(access: .shared))
        tabs.add("Appearance", symbol: "paintpalette", AppearancePane(prefs: .shared))
        tabs.add("Agents", symbol: "terminal", AgentsPane())
        tabs.add("Permissions", symbol: "checkmark.shield", PermissionsPane())
        tabs.add("Accounts", symbol: "person.crop.circle", AccountsPane(store: .shared, monitor: .shared, login: .shared, team: .shared, teams: .shared))
        tabs.add("Command", symbol: "command", CommandPane())
        tabs.add("Teams & Phone", symbol: "person.2", ConnectionsPane())
        if CloudAccount.isEnabled { tabs.add("Cloud", symbol: "cloud", CloudPane(account: .shared, teams: .shared)) }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.fitWindow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    #if DEBUG
    /// For the self-test's snapshots.
    var paneCount: Int { (contentViewController as? NSTabViewController)?.tabViewItems.count ?? 0 }
    func selectPane(_ index: Int) { (contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = index }
    #endif

    /// Opens the pane with this title.
    func show(pane title: String) {
        let tabs = contentViewController as? NSTabViewController
        if let index = tabs?.tabViewItems.firstIndex(where: { $0.label == title }) { tabs?.selectedTabViewItemIndex = index }
        show()
    }

    func show() {
        DiskAccessMonitor.shared.refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Resizes the window to each pane's height, keeping its top edge still, and titles it after the pane.
private final class SettingsTabs: NSTabViewController {
    static let width: CGFloat = 600

    func add<Pane: View>(_ label: String, symbol: String, _ pane: Pane) {
        let host = NSHostingController(rootView: pane.formStyle(.grouped).frame(width: Self.width).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = [.preferredContentSize]
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow()
    }

    /// A pane grew or shrank (e.g. the pairing code appeared).
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === tabViewItems[selectedTabViewItemIndex].viewController { fitWindow() }
    }

    func fitWindow() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController, let window = view.window else { return }
        var size = pane.preferredContentSize.height > 0 ? pane.preferredContentSize : pane.view.fittingSize
        if let screen = window.screen ?? NSScreen.main { size.height = min(size.height, screen.visibleFrame.height - 120) }
        let current = window.contentRect(forFrameRect: window.frame)
        let content = NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(window.frameRect(forContentRect: content), display: true, animate: window.isVisible)
    }
}

/// Grey explanatory text under a section, wrapping to the pane's width.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralPane: View {
    @ObservedObject var access: DiskAccessMonitor
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    @AppStorage(Notifier.attentionKey) private var notifyAttention = true
    @AppStorage(Notifier.completeKey) private var notifyComplete = true
    @AppStorage(Notifier.soundKey) private var notifySound = true

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    private static let oldHelperNote = "Your tabs are running in a session helper from another version of agterm. "
        + "To update it, choose agterm → Quit and End Sessions."
    /// Read when Settings is built; the helper in use changes only if it dies and another starts.
    private let helperIsOld = SessionHelper.runsOtherBuild

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("When an agent needs you", isOn: $notifyAttention)
                Toggle("When an agent finishes", isOn: $notifyComplete)
                Toggle("Play a sound", isOn: $notifySound)
            }

            if Updater.shared.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { _, on in Updater.shared.automaticallyChecks = on }
                    LabeledContent("Version \(Self.version)") {
                        Button("Check Now") { Updater.shared.checkForUpdates(nil) }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    if helperIsOld { Footnote(Self.oldHelperNote) }
                }
            } else if helperIsOld {
                Section { Footnote(Self.oldHelperNote) }
            }

            Section {
                DiskAccessRow(status: access.status)
            } header: {
                Text("Full Disk Access")
            } footer: {
                Footnote("Agents and tools you run in agterm get the same access as agterm itself. "
                         + "Without Full Disk Access, macOS blocks them from Desktop, Documents, Mail and other apps' data.")
            }
        }
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @ObservedObject var prefs: Preferences
    private var settings: AppearanceSettings { prefs.appearance }

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(ThemeCatalog.all) { theme in
                        ThemeSwatch(theme: theme, selected: theme.id == settings.themeID) {
                            prefs.update { $0.themeID = theme.id }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Font") {
                Picker("Family", selection: binding(\.fontFamily)) {
                    Text("System Mono (SF Mono)").tag(String?.none)
                    Divider()
                    ForEach(Theme.monospacedFamilies, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Stepper(value: binding(\.fontSize), in: AppearanceSettings.fontSizeRange, step: 1) {
                    LabeledContent("Size", value: "\(Int(settings.fontSize)) pt")
                }
                FontPreview(settings: settings)
            }

            Section("Window") {
                LabeledContent("Background opacity") {
                    HStack {
                        Slider(value: binding(\.opacity), in: AppearanceSettings.opacityRange)
                        Text("\(Int((settings.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Blur") {
                    HStack {
                        Slider(value: binding(\.blur), in: 0...1)
                        Text(settings.blur == 0 ? "Off" : "\(Int((settings.blur * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(settings.opacity >= 1)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
        Binding(get: { prefs.appearance[keyPath: keyPath] },
                set: { value in prefs.update { $0[keyPath: keyPath] = value } })
    }
}

private struct ThemeSwatch: View {
    let theme: ThemePalette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text("~ % ").foregroundColor(color(theme.fg))
                        Text("ls").foregroundColor(color(theme.ansi[4]))
                        Rectangle().fill(color(theme.accent)).frame(width: 2, height: 11).padding(.leading, 2)
                    }
                    HStack(spacing: 5) {
                        ForEach([1, 2, 3, 5, 6], id: \.self) { i in
                            Rectangle().fill(color(theme.ansi[i])).frame(width: 9, height: 4)
                        }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
                .background(color(theme.bg), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                                  lineWidth: selected ? 2 : 1))
                Text(theme.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func color(_ rgb: RGB) -> Color { Color(nsColor: Theme.color(rgb)) }
}

private struct FontPreview: View {
    let settings: AppearanceSettings

    var body: some View {
        let theme = settings.theme
        Text("claude ◐ Fix login redirect loop\n$ git diff --stat  +75 −12")
            .font(Font(Theme.terminalFont(family: settings.fontFamily, size: CGFloat(settings.fontSize))))
            .foregroundColor(Color(nsColor: Theme.color(theme.fg)))
            .lineLimit(2)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: Theme.color(theme.bg, alpha: CGFloat(settings.opacity))),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DiskAccessRow: View {
    let status: DiskAccess

    var body: some View {
        HStack {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(label)
            Spacer()
            if status != .granted {
                Button("Open System Settings…") { DiskAccessMonitor.openSystemSettings() }
            }
        }
    }

    private var label: String {
        switch status {
        case .granted: "Granted"
        case .denied: "Not granted"
        case .unknown: "Couldn't check"
        }
    }

    private var dotColor: Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .unknown: .secondary
        }
    }
}

