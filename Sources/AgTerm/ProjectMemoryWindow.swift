import AgTermCore
import AppKit
import SwiftUI

/// What Window → Project Memory shows: the entries agents saved for one repo and its latest
/// session handoffs, read from the memory server's store.
final class ProjectMemoryModel: ObservableObject {
    @Published private(set) var repo: String?
    @Published private(set) var entries: [ProjectMemoryDigest.Entry] = []
    @Published private(set) var handoffs: [ProjectMemoryDigest.Handoff] = []
    private(set) var dataDir: String?
    private var cwd = NSHomeDirectory()

    static let handoffLimit = 10

    func load(cwd: String) {
        self.cwd = cwd
        reload()
    }

    func reload() {
        let memory = AgentIntegration.projectMemory(cwd)
        repo = memory?.project.repoPath
        dataDir = memory?.dataDir
        let files = FileManager.default
        entries = ProjectMemoryDigest.currentEntries(memory.flatMap { files.contents(atPath: $0.store) })
        handoffs = ProjectMemoryDigest.recentHandoffs(memory.flatMap { files.contents(atPath: $0.handoffStore) }, limit: Self.handoffLimit)
    }
}

/// Window → Project Memory, for the repo of the tab you're in.
final class ProjectMemoryWindowController: NSWindowController {
    static let shared = ProjectMemoryWindowController()
    let model = ProjectMemoryModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Project Memory"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = NSHostingView(rootView: ProjectMemoryView(model: model))
        super.init(window: window)
        window.center()
        window.setFrameAutosaveName("agterm.projectMemory")
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(cwd: String) {
        applyAppearance()
        model.load(cwd: cwd)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func applyAppearance() {
        window?.appearance = Theme.appearance
        window?.backgroundColor = Theme.color(Theme.palette.bg)
    }
}

struct ProjectMemoryView: View {
    @ObservedObject var model: ProjectMemoryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.repo == nil {
                    note("This tab's folder isn't in a git repo, so agents started here have no project memory.")
                } else if !AgentIntegration.wantMemory {
                    note("Project memory is off in Settings → Agents, so agents don't read or save it.")
                }
                if model.repo != nil {
                    saved
                    handoffs
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .id(Theme.palette.id)
        }
        .background(UsageInk.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Project memory").font(.system(size: 22, weight: .semibold)).foregroundStyle(UsageInk.fg)
                Spacer()
                if let dir = model.dataDir {
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir) }
                        .buttonStyle(.borderless).foregroundStyle(UsageInk.fg2)
                }
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(UsageInk.fg2)
                    .help("Read the memory again")
            }
            Text(model.repo.map { "What agents saved for \(($0 as NSString).lastPathComponent). Every agent that starts in this repo sees it." }
                 ?? "What agents save about a repo, shared by every agent that works in it.")
                .font(.system(size: 12)).foregroundStyle(UsageInk.fg3)
                .help(model.repo.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
        }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Saved", count: model.entries.count)
            if model.entries.isEmpty {
                empty("Nothing saved yet. Agents save decisions, gotchas and conventions here as they learn them.")
            }
            ForEach(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 { divider }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title).font(.system(size: 13, weight: .medium)).foregroundStyle(UsageInk.fg)
                        Spacer(minLength: 8)
                        Text(label(entry)).font(.system(size: 11)).foregroundStyle(UsageInk.fg3)
                    }
                    if !entry.content.isEmpty {
                        Text(entry.content).font(.system(size: 12)).foregroundStyle(UsageInk.fg2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var handoffs: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Latest handoffs", count: model.handoffs.count)
            if model.handoffs.isEmpty {
                empty("No handoffs yet. An agent writes one when it finishes work that changed files.")
            }
            ForEach(Array(model.handoffs.enumerated()), id: \.offset) { index, handoff in
                if index > 0 { divider }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(handoff.title).font(.system(size: 13, weight: .medium)).foregroundStyle(UsageInk.fg)
                        Spacer(minLength: 8)
                        Text(date(handoff.updated)).font(.system(size: 11).monospacedDigit()).foregroundStyle(UsageInk.fg3)
                    }
                    Text(handoff.summary).font(.system(size: 12)).foregroundStyle(UsageInk.fg2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: Pieces

    private func section(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(UsageInk.fg)
            if count > 0 { Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(UsageInk.fg3) }
        }
        .padding(.bottom, 4)
    }

    private var divider: some View { Rectangle().fill(UsageInk.border).frame(height: 1) }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(UsageInk.fg3).padding(.vertical, 8)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(UsageInk.fg2)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(UsageInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UsageInk.border))
    }

    /// "Decision · binding · Nov 12".
    private func label(_ entry: ProjectMemoryDigest.Entry) -> String {
        var parts = [entry.kind.capitalized]
        if entry.binding { parts.append("binding") } else if entry.important { parts.append("important") }
        parts.append(date(entry.updated))
        return parts.joined(separator: " · ")
    }

    private func date(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter.withFractions.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return String(iso.prefix(10))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
