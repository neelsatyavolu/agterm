import AgTermCore
import SwiftUI

/// The Mac's tabs in the Mac's order, drawn like its tab cards.
struct TabListView: View {
    @EnvironmentObject private var remote: Remote
    @State private var confirmForget = false
    @State private var newTab = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ConnectionBanner()
                    ForEach(remote.tabs) { tab in
                        NavigationLink(value: tab.id) { TabRowView(tab: tab) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tab-row")
                        Hairline()
                    }
                    if remote.tabs.isEmpty, remote.link == .online {
                        Text("No tabs open in agterm.")
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.fg3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
            }
            .background(Ink.bg)
            .navigationTitle(remote.macName.map(Self.shortName) ?? "agterm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Ink.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { newTab = true } label: { Image(systemName: "plus").foregroundStyle(Ink.fg2) }
                        .disabled(remote.newTabOptions == nil || remote.link != .online)
                        .accessibilityLabel("New Tab")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Forget This Mac", role: .destructive) { confirmForget = true }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Ink.fg2)
                    }
                }
            }
            .confirmationDialog("Forget this Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget This Mac", role: .destructive) { remote.forget() }
            } message: {
                Text("This iPhone stops showing the Mac's tabs until you pair it again.")
            }
            .navigationDestination(for: String.self) { TabDetailView(tabID: $0) }
            // Once paired: ask (iOS asks only once) so "needs you" and "finished" reach a closed app.
            .task { await Push.shared.requestPermission() }
            .sheet(isPresented: $newTab) {
                if let options = remote.newTabOptions { NewTabSheet(options: options) }
            }
            // The Mac opened the tab asked for: show it.
            // `initial`: a notification tap can launch the app before this view exists.
            .onChange(of: remote.openedTab, initial: true) { _, opened in
                guard let opened else { return }
                path = [opened]
                remote.openedTab = nil
            }
        }
    }

    /// "agterm on Neel's MacBook Pro" → "Neel's MacBook Pro".
    static func shortName(_ name: String) -> String {
        name.hasPrefix("agterm on ") ? String(name.dropFirst("agterm on ".count)) : name
    }
}

/// Says why nothing is moving when the phone isn't talking to the Mac.
struct ConnectionBanner: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                Circle().fill(remote.link == .macOffline ? Ink.fg3 : Ink.accent).frame(width: 7, height: 7)
                Text(text).font(.system(size: 13)).foregroundStyle(Ink.fg2)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Ink.surface)
            Hairline()
        }
    }

    private var text: String? {
        switch remote.link {
        case .online, .unpaired: nil
        case .connecting: "Connecting…"
        case .macOffline: "The Mac is offline. Open agterm, and check the phone is on in Settings → Teams & Phone."
        }
    }
}

/// ● Topic
///   WORKING  folder  branch          +75 −12
struct TabRowView: View {
    let tab: RemoteTabRow

    private var status: TabStatus { tab.agterm?.tabStatus ?? (tab.needsApproval ? .waiting : tab.processing ? .working : .idle) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: status).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(tab.title.isEmpty ? "Terminal" : tab.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Ink.fg)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if status != .idle {
                        Text(status.label.uppercased()).font(Ink.label).tracking(0.8).foregroundStyle(status.color)
                    }
                    Text(tab.agterm?.folder ?? tab.projectName ?? "").font(Ink.mono(12)).foregroundStyle(Ink.fg3)
                    if let branch = tab.agterm?.branch {
                        Text(branch).font(Ink.mono(12)).foregroundStyle(Ink.fg4).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let added = tab.linesAdded, let removed = tab.linesRemoved {
                        DiffText(added: added, removed: removed)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct StatusDot: View {
    let status: TabStatus

    var body: some View {
        if status == .idle {
            Circle().stroke(Ink.fg4, lineWidth: 1).frame(width: 7, height: 7)
        } else {
            Circle().fill(status.color).frame(width: 7, height: 7)
        }
    }
}

struct DiffText: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(Ink.ok)
            Text("−\(removed)").foregroundStyle(Ink.danger)
        }
        .font(Ink.mono(12))
        .monospacedDigit()
    }
}
