import AgTermCore
import SwiftUI

/// Opens a tab on the Mac: an agent (or a plain shell) in one of the folders the Mac offers.
struct NewTabSheet: View {
    let options: NewTabOptions
    @EnvironmentObject private var remote: Remote
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newTabAgent") private var agent = "claude"
    @State private var folder = ""

    private var choices: [NewTabOptions.Agent] {
        options.agents + [NewTabOptions.Agent(id: AgTermWire.shellProvider, title: "Shell")]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    label("AGENT")
                    ForEach(choices, id: \.id) { choice in
                        row(choice.title, detail: nil, chosen: agent == choice.id) { agent = choice.id }
                    }
                    label("FOLDER").padding(.top, 16)
                    ForEach(options.folders, id: \.self) { path in
                        row(PathDisplay.folder(path, home: options.home), detail: shortPath(path), chosen: folder == path) {
                            folder = path
                        }
                    }
                }
            }
            .background(Ink.bg)
            .navigationTitle("New Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Ink.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if remote.openingTab {
                        ProgressView().tint(Ink.fg2)
                    } else {
                        Button("Open") { remote.openTab(provider: agent, folder: folder) }
                            .disabled(folder.isEmpty || remote.link != .online)
                    }
                }
            }
            .safeAreaInset(edge: .top) { NoticeBanner() }
        }
        .onAppear {
            if !choices.contains(where: { $0.id == agent }) { agent = choices.first?.id ?? AgTermWire.shellProvider }
            if folder.isEmpty { folder = options.folders.first ?? "" }
        }
        .onChange(of: remote.openedTab) { _, opened in
            if opened != nil { dismiss() }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Ink.label).tracking(1).foregroundStyle(Ink.fg3)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
    }

    private func row(_ title: String, detail: String?, chosen: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16)).foregroundStyle(Ink.fg)
                    if let detail { Text(detail).font(Ink.mono(12)).foregroundStyle(Ink.fg3).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(Ink.accent) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func shortPath(_ path: String) -> String {
        path == options.home ? "~" : path.hasPrefix(options.home + "/") ? "~" + path.dropFirst(options.home.count) : path
    }
}
