import AgTermCore
import AppKit
import Combine
import SwiftUI

/// Window → Team Dashboard: your agterm Teams team's usage and shared logins, without agmux.
/// Fetches when it opens and on Refresh; nothing runs while it's closed.
@MainActor
final class TeamsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TeamsWindowController()
    private var themeWatch: AnyCancellable?

    private init() {
        let host = NSHostingController(rootView: TeamsRootView(store: .shared, account: .shared, prefs: .shared))
        let window = NSWindow(contentViewController: host)
        window.title = "Team Dashboard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 760))
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TeamDashboard")
        super.init(window: window)
        window.delegate = self
        // The title bar follows the theme, light or dark.
        themeWatch = Preferences.shared.$appearance.sink { [weak window] settings in
            window?.appearance = NSAppearance(named: settings.theme.isDark ? .darkAqua : .aqua)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        TeamDashboardStore.shared.refresh()
    }
}

struct TeamsRootView: View {
    @ObservedObject var store: TeamDashboardStore
    @ObservedObject var account: TeamsAccount
    @ObservedObject var prefs: Preferences

    var body: some View {
        let colors = TeamsColors(palette: prefs.appearance.theme)
        VStack(spacing: 0) {
            if store.signedIn, !store.teams.isEmpty { header(colors) }
            ScrollView {
                content(colors).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(colors.bg)
        .environment(\.teams, colors)
        .environment(\.colorScheme, colors.colorScheme)
    }

    // MARK: Header

    private func header(_ c: TeamsColors) -> some View {
        HStack(spacing: 10) {
            if store.teams.count > 1 {
                Picker("Team", selection: Binding(get: { store.teamID ?? "" }, set: { store.teamID = $0 })) {
                    ForEach(store.teams) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            } else if let team = store.team {
                Text(team.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(c.fg)
            }
            if let team = store.team { TeamsRoleBadge(role: team.role) }
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(c.fg3).lineLimit(1)
            Spacer()
            Picker("Range", selection: $store.range) {
                ForEach(TeamDashboard.Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { store.refresh() } label: {
                if store.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Refresh").disabled(store.loading).frame(width: 30)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(c.border).frame(height: 1) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let overview = store.overview, overview.scope != .self { parts.append(overview.peopleLine) }
        if let ago = TeamDashboard.ago(store.overview?.lastUploadAt) { parts.append("last upload \(ago)") }
        return parts.joined(separator: " · ")
    }

    // MARK: States

    @ViewBuilder
    private func content(_ c: TeamsColors) -> some View {
        if !store.signedIn {
            TeamsEmptyState(symbol: "person.2", title: "Sign in to agterm Teams",
                            message: "The Team Dashboard shows your team's usage once this Mac is signed in to agterm Teams.",
                            action: ("Open Settings", { SettingsWindowController.shared.show(pane: "Teams & Phone") }))
        } else if !store.teamsLoaded {
            loadingOrFailure
        } else if store.teams.isEmpty {
            TeamsEmptyState(symbol: "person.2.slash", title: "You're not on a team",
                            message: "Open the invite link your team's owner sent you, or create a team on agterm Teams.",
                            action: ("Open agterm Teams", { NSWorkspace.shared.open(TeamsAccount.baseURL) }))
        } else if let overview = store.overview {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = store.failure { staleBanner(failure) }
                switch overview.state {
                case .selfOnly: selfView
                case .waiting:
                    TeamsEmptyState(symbol: "clock", title: "Waiting for first sync",
                                    message: "No usage has arrived yet. Members show up once their agterm or agmux app uploads.")
                    if overview.role.isAdmin { TeamLoginsPanel(store: store) }
                case .full: TeamDashboardView(overview: overview, store: store)
                }
            }
        } else {
            loadingOrFailure
        }
    }

    @ViewBuilder
    private var loadingOrFailure: some View {
        if let failure = store.failure {
            TeamsEmptyState(symbol: failure == .offline ? "wifi.slash" : "exclamationmark.triangle",
                            title: failure == .offline ? "You're offline" : "Couldn't load the dashboard",
                            message: failure.localizedDescription, action: ("Try Again", { store.refresh() }))
        } else {
            ProgressView("Loading…").controlSize(.small).frame(maxWidth: .infinity).padding(60)
        }
    }

    private func staleBanner(_ failure: TeamDashboard.Failure) -> some View {
        let when = store.fetchedAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
        let shown = when.map { "Showing numbers from \($0)." } ?? "Showing the last numbers fetched."
        let lead = failure == .offline ? "Offline." : failure.localizedDescription
        return TeamsBanner(text: "\(lead) \(shown)", warning: failure != .offline)
    }

    @ViewBuilder
    private var selfView: some View {
        TeamsBanner(text: "Your role on this team shows your own numbers only.")
        if let me = store.me {
            TeamMemberDetailContent(detail: me, range: store.range)
        } else if store.loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
        }
    }
}
