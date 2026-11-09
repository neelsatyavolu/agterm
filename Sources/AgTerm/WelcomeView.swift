import AppKit
import SwiftUI

/// The welcome window's content: a header, the features by group, and the two buttons.
/// Colors come from the current theme, so it reads in Ink and Paper alike.
struct WelcomeView: View {
    let showChangelog: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(color(Theme.border))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Welcome.groups) { group in section(group) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            Divider().overlay(color(Theme.border))
            footer
        }
        .frame(width: 640, height: 680)
        .background(color(Theme.color(Theme.palette.bg)))
        .tint(color(Theme.accent))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("agterm 1.2")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color(Theme.fg))
            Text("Everything new since \(Welcome.since), and the settings that come with it.")
                .font(.system(size: 13))
                .foregroundStyle(color(Theme.fg2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }

    private func section(_ group: Welcome.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(Theme.fg3))
            VStack(spacing: 0) {
                ForEach(Array(group.features.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { Divider().overlay(color(Theme.border)).padding(.leading, 48) }
                    WelcomeRow(feature: feature)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(color(Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color(Theme.border), lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack {
            Button("See Every Change", action: showChangelog)
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }
}

/// One feature: its symbol, name and one or two lines, and its control on the right.
private struct WelcomeRow: View {
    let feature: Welcome.Feature

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(color(Theme.accent))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color(Theme.fg))
                Text(feature.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(color(Theme.fg2))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var control: some View {
        switch feature.control {
        case .none:
            EmptyView()
        case .shortcut(let keys):
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(Theme.fg2))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color(Theme.border), lineWidth: 1))
        case .hint(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color(Theme.fg3))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110, alignment: .trailing)
        case .toggle(let key, let defaultOn, let changed):
            WelcomeToggle(key: key, defaultOn: defaultOn, changed: changed)
        case .button(let title, let action):
            Button(title, action: action)
        }
    }
}

/// A switch bound to a UserDefaults key that may not be set yet.
private struct WelcomeToggle: View {
    let key: String
    let defaultOn: Bool
    let changed: () -> Void
    @State private var on = false

    var body: some View {
        Toggle("", isOn: $on)
            .labelsHidden()
            .toggleStyle(.switch)
            .onAppear { on = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn }
            .onChange(of: on) { _, value in
                guard value != (UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn) else { return }
                UserDefaults.standard.set(value, forKey: key)
                changed()
            }
    }
}

private func color(_ ns: NSColor) -> Color { Color(nsColor: ns) }
