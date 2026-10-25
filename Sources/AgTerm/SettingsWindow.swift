import AgTermCore
import AppKit
import SwiftUI

/// ⌘, — one window, reused.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(prefs: .shared, access: .shared)))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        DiskAccessMonitor.shared.refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var access: DiskAccessMonitor

    private var settings: AppearanceSettings { prefs.appearance }
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    @AppStorage(AgentIntegration.memoryKey) private var memory = true
    @AppStorage(Notifier.attentionKey) private var notifyAttention = true
    @AppStorage(Notifier.completeKey) private var notifyComplete = true
    @AppStorage(Notifier.soundKey) private var notifySound = true
    @AppStorage(AgentIntegration.consultKey) private var consult = true

    /// Checked once when Settings opens.
    private static let agentStatus: String = {
        let base = "claude and codex started in agterm get these MCP servers, the same ones agmux gives its agents. "
            + "Memory is shared with agmux for folders it knows; servers you already configured aren't added twice. "
            + "Start an agent with AGTERM_MCP=0 to skip them once."
        guard AgentIntegration.agmuxBundles() != nil else {
            return "agmux isn't installed, so there are no servers to add. " + base
        }
        guard AgentIntegration.findOnPath("node", excluding: nil) != nil else {
            return "Node.js wasn't found on agterm's PATH; agents' own shells may still find it. " + base
        }
        return base
    }()
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

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

            Section("Notifications") {
                Toggle("When an agent needs you", isOn: $notifyAttention)
                Toggle("When an agent finishes", isOn: $notifyComplete)
                Toggle("Play a sound", isOn: $notifySound)
            }

            Section {
                Toggle("agmux project memory", isOn: $memory)
                Toggle("consult", isOn: $consult)
            } header: {
                Text("Agents")
            } footer: {
                Text(Self.agentStatus)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if Updater.shared.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { _, on in Updater.shared.automaticallyChecks = on }
                    LabeledContent("Version \(Self.version)") {
                        Button("Check Now") { Updater.shared.checkForUpdates(nil) }
                    }
                }
            }

            Section {
                DiskAccessRow(status: access.status)
            } header: {
                Text("Full Disk Access")
            } footer: {
                Text("Agents and tools you run in agterm get the same access as agterm itself. "
                     + "Without Full Disk Access, macOS blocks them from Desktop, Documents, Mail and other apps' data.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
