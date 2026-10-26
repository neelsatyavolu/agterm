import AgTermCore
import SwiftUI
import UIKit

/// One tab: its live screen (or, for Claude Code and Codex, the conversation), any prompt
/// waiting for an answer, keys to press, and a reply box.
struct TabDetailView: View {
    let tabID: String
    @EnvironmentObject private var remote: Remote
    @AppStorage("detailMode") private var mode = Mode.screen
    @State private var draft = ""
    @FocusState private var typing: Bool

    enum Mode: String { case screen, chat }

    private var tab: RemoteTabRow? { remote.tabs.first { $0.id == tabID } }
    private var status: TabStatus { tab?.agterm?.tabStatus ?? .idle }
    /// agterm builds conversations from Claude Code and Codex transcripts only.
    private var hasChat: Bool { ["claude", "codex"].contains(tab?.agterm?.agent ?? "") }
    private var showsChat: Bool { hasChat && mode == .chat }

    var body: some View {
        VStack(spacing: 0) {
            if let tab {
                header(tab)
                Hairline()
                ConnectionBanner()
                if showsChat {
                    ChatView(entries: remote.timelines[tabID])
                } else {
                    ScreenView(snapshot: remote.screens[tabID])
                }
                Hairline()
                if let prompt = tab.agterm?.prompt {
                    PromptCard(prompt: prompt) { remote.press(text: $0, in: tabID) } cancel: { remote.press([.esc], in: tabID) }
                    Hairline()
                }
                KeyBar { remote.press([$0], in: tabID) }
                Hairline()
                composer
            } else {
                Text("This tab was closed on the Mac.")
                    .font(.system(size: 15)).foregroundStyle(Ink.fg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Ink.bg)
        .navigationTitle(tab?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Ink.bg, for: .navigationBar)
        .toolbar {
            if hasChat {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        Text("Screen").tag(Mode.screen)
                        Text("Chat").tag(Mode.chat)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
        }
        .overlay(alignment: .top) { NoticeBanner() }
        .onAppear { remote.watch(tabID, chat: showsChat) }
        .onDisappear { remote.stopWatching(tabID) }
        .onChange(of: showsChat) { _, chat in remote.watch(tabID, chat: chat) }
        .onChange(of: remote.returnedDraft) { _, returned in
            if let returned, returned.tab == tabID, draft.isEmpty { draft = returned.text }
        }
    }

    private func header(_ tab: RemoteTabRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
            Text(status.label.uppercased()).font(Ink.label).tracking(0.8).foregroundStyle(status.color)
            Text(tab.agterm?.folder ?? "").font(Ink.mono(12)).foregroundStyle(Ink.fg3)
            if let branch = tab.agterm?.branch { Text(branch).font(Ink.mono(12)).foregroundStyle(Ink.fg4) }
            Spacer(minLength: 8)
            if let added = tab.linesAdded, let removed = tab.linesRemoved { DiffText(added: added, removed: removed) }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Reply", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .foregroundStyle(Ink.fg)
                .focused($typing)
                .accessibilityIdentifier("reply")
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(Rectangle().stroke(typing ? Ink.accent : Ink.border, lineWidth: 1))
            if status == .working && draft.isEmpty {
                Button("Stop") { remote.interrupt(tabID) }
                    .buttonStyle(InkButtonStyle(kind: .ghost))
            } else {
                Button("Send", action: send)
                    .buttonStyle(InkButtonStyle(kind: .primary))
                    .accessibilityIdentifier("send")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remote.link != .online)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if remote.reply(text, to: tabID) { draft = "" }
    }
}

/// The agent's question with its numbered answers as buttons.
struct PromptCard: View {
    let prompt: PromptInfo
    let choose: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(prompt.question ?? "The agent is waiting for an answer.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.fg)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            ForEach(prompt.choices, id: \.key) { choice in
                Hairline()
                Button { tap(); choose(choice.key) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(choice.key).font(Ink.mono(13, .medium)).foregroundStyle(Ink.accent)
                        Text(choice.label).font(.system(size: 15)).foregroundStyle(Ink.fg)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Hairline()
            Button { tap(); cancel() } label: {
                HStack(spacing: 12) {
                    Text("esc").font(Ink.mono(13, .medium)).foregroundStyle(Ink.fg3)
                    Text("Cancel").font(.system(size: 15)).foregroundStyle(Ink.fg2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Ink.surface)
    }

    private func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

/// Keys a phone keyboard doesn't have.
struct KeyBar: View {
    let press: (TerminalKey) -> Void

    private static let keys: [(TerminalKey, String)] = [
        // Most used first, so they're on screen without scrolling.
        (.esc, "esc"), (.ctrlC, "^C"), (.enter, "⏎"), (.up, "↑"), (.down, "↓"), (.tab, "tab"),
        (.shiftTab, "⇧tab"), (.left, "←"), (.right, "→"), (.backspace, "⌫"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.keys, id: \.0) { key, title in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        press(key)
                    } label: {
                        Text(title)
                            .font(Ink.mono(14, .medium))
                            .foregroundStyle(Ink.fg)
                            .frame(minWidth: 40, minHeight: 34)
                            .padding(.horizontal, 4)
                            .overlay(Rectangle().stroke(Ink.borderStrong, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key.rawValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// Errors from the Mac, such as a tab that closed, for a few seconds.
struct NoticeBanner: View {
    @EnvironmentObject private var remote: Remote

    var body: some View {
        if let notice = remote.notice {
            Text(notice)
                .font(.system(size: 13))
                .foregroundStyle(Ink.fg)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.bg)
                .overlay(Rectangle().stroke(Ink.danger, lineWidth: 1))
                .padding(12)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    if remote.notice == notice { remote.notice = nil }
                }
        }
    }
}
