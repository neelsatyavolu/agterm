import AgTermCore
import SwiftUI

/// Settings → Accounts: your logins for each agent, their usage, and automatic switching.
struct AccountsPane: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var login: AccountLogin
    @ObservedObject var team: TeamAccounts
    @ObservedObject var teams: TeamsAccount
    @State private var installed: Set<AccountProvider>?

    var body: some View {
        Form {
            Section {
                Toggle("Switch accounts when an agent runs out of usage", isOn: binding(\.autoSwitch))
                Toggle("Then tell the agent to continue", isOn: binding(\.continueAfterSwitch))
                    .disabled(!store.settings.autoSwitch)
            } header: {
                Text("Automatic switching")
            } footer: {
                Footnote("When Claude Code or Codex stops at its usage limit, agterm sees it in the conversation within "
                         + "a second; Grok's usage is checked every minute while it runs. agterm then checks your other "
                         + "accounts and resumes the same conversation in the same tab on the one with the most left. "
                         + "New sessions start on your own login while it has usage. Every account shares your "
                         + "conversations, settings and MCP servers. Codex and Grok can also borrow a login your team "
                         + "shares in agmux Teams once all of yours are out.")
            }

            ForEach(providers, id: \.self) { provider in
                ProviderSection(provider: provider, store: store, monitor: monitor, login: login)
            }

            if teams.isSignedIn || team.isConnected, !shareable.isEmpty,
               !team.accounts.isEmpty || team.error != nil || !team.addableTeams.isEmpty || login.teamJob != nil {
                TeamSection(team: team, login: login, providers: shareable)
            }
        }
        .task {
            team.refresh()
            installed = await Task.detached {
                Set(AccountProvider.allCases.filter { QuickCommandRunner.shared.executable($0.rawValue) != nil })
            }.value
            for provider in providers where monitor.reading(provider, AccountStore.native) == nil {
                for id in monitor.ids(provider) { monitor.refresh(provider, id) }
            }
        }
    }

    private var providers: [AccountProvider] { AccountProvider.allCases.filter { installed?.contains($0) ?? true } }
    private var shareable: [AccountProvider] { providers.filter(\.teamShareable) }

    private func binding(_ keyPath: WritableKeyPath<AccountStore.Settings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in store.update { $0[keyPath: keyPath] = value } })
    }
}

private struct ProviderSection: View {
    let provider: AccountProvider
    @ObservedObject var store: AccountStore
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var login: AccountLogin

    var body: some View {
        Section {
            AccountRow(title: "Your login", subtitle: subtitle(email: nil, plan: nil, id: AccountStore.native),
                       reading: monitor.reading(provider, AccountStore.native),
                       error: monitor.errors[UsageMonitor.key(provider, AccountStore.native)],
                       checking: monitor.checking.contains(UsageMonitor.key(provider, AccountStore.native)))
            ForEach(store.accounts(provider)) { account in
                AccountRow(title: account.label, subtitle: subtitle(email: account.email, plan: account.plan, id: account.id),
                           reading: monitor.reading(provider, account.id),
                           error: monitor.errors[UsageMonitor.key(provider, account.id)],
                           checking: monitor.checking.contains(UsageMonitor.key(provider, account.id)),
                           enabled: account.enabled) {
                    Menu {
                        Button(account.enabled ? "Don't Switch to This Account" : "Switch to This Account Again") {
                            var changed = account
                            changed.enabled.toggle()
                            store.add(changed)
                        }
                        Button("Check Usage") { monitor.refresh(provider, account.id) }
                        Divider()
                        Button("Remove", role: .destructive) { store.remove(account.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            HStack {
                if login.pending[provider] != nil {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the sign-in…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { login.cancel(provider) }
                } else {
                    Button("Add \(provider.title) Account…") { login.start(provider) }
                    Spacer()
                    Button("Check Usage") { for id in monitor.ids(provider) { monitor.refresh(provider, id) } }
                }
            }
        } header: {
            Text(provider.title)
        } footer: {
            if let message = login.message[provider] { Footnote(message) }
        }
    }

    private func subtitle(email: String?, plan: String?, id: String) -> String {
        let reading = monitor.reading(provider, id)
        return [reading?.email ?? email, reading?.plan ?? plan].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Codex and Grok logins shared through agmux Teams. Owners and managers can add one here;
/// renaming, pausing and removing them happen in agmux.
private struct TeamSection: View {
    @ObservedObject var team: TeamAccounts
    @ObservedObject var login: AccountLogin
    /// Installed agents whose logins a team can share.
    let providers: [AccountProvider]

    var body: some View {
        Section {
            ForEach(team.accounts.filter { providers.contains($0.provider) }) { account in
                AccountRow(title: account.label,
                           subtitle: [account.provider.title, account.teamName, account.plan].compactMap { $0 }.joined(separator: " · "),
                           reading: reading(account), error: nil, checking: team.checking.contains(account.id), note: note(account)) {
                    Menu {
                        Button("Check Usage") { team.check(account) }
                            .disabled(account.leased(Date()) || !account.enabled)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if let job = login.teamJob {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the \(job.provider.title) sign-in for \(job.team.name)…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { login.cancelTeam() }
                }
            } else if !team.addableTeams.isEmpty {
                HStack {
                    Menu("Add Team Account…") {
                        ForEach(team.addableTeams) { target in
                            ForEach(providers, id: \.self) { provider in
                                Button(team.addableTeams.count > 1 ? "\(provider.title) for \(target.name)" : provider.title) {
                                    login.start(provider, team: target)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
        } header: {
            Text("Shared by your team")
        } footer: {
            Footnote(login.teamMessage ?? team.error ?? "From agmux Teams. agterm borrows one of these only when every login "
                     + "of yours for that agent is out, keeps it for that tab, and gives it back when the agent exits. "
                     + (team.addableTeams.isEmpty ? "" : "An account you add is signed in once, for the team; agterm keeps no copy."))
        }
    }

    /// Usage measured here if it's the newest, else what the team last reported.
    private func reading(_ account: TeamPool.Account) -> UsageReading? {
        if let mine = team.readings[account.id], mine.checkedAt >= (account.checkedAt ?? .distantPast) { return mine }
        guard let remaining = account.shownRemaining(Date()) else { return nil }
        return UsageReading(windows: [UsageWindow(name: "Usage", usedPercent: 100 - remaining, resetsAt: account.blockedUntil)],
                            checkedAt: account.checkedAt ?? Date())
    }

    private func note(_ account: TeamPool.Account) -> String? {
        let now = Date()
        if let problem = team.checkErrors[account.id] { return problem }
        if !account.enabled { return "Paused by your team" }
        if account.leased(now) { return account.inUseMine ? "In use by you" : "In use by \(account.inUseBy ?? "a teammate")" }
        if let until = account.blockedUntil, until > now { return "Out of usage until \(until.formatted(date: .omitted, time: .shortened))" }
        if account.remainingPercent == 0 { return "Out of usage" }
        if account.remainingPercent == nil, let checked = account.checkedAt {
            return "Checked \(checked.formatted(.relative(presentation: .named)))"
        }
        return nil
    }
}

/// One login: name, email and plan, and a bar per usage window.
private struct AccountRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let reading: UsageReading?
    let error: String?
    let checking: Bool
    var enabled = true
    var note: String?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, subtitle: String, reading: UsageReading?, error: String?, checking: Bool, enabled: Bool = true,
         note: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.reading = reading
        self.error = error
        self.checking = checking
        self.enabled = enabled
        self.note = note
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(enabled ? .primary : .secondary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let note = enabled ? note : "Not used for switching" {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let reading, !reading.windows.isEmpty {
                    ForEach(reading.windows, id: \.name) { UsageBar(window: $0) }
                } else if checking {
                    ProgressView().controlSize(.small)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            accessory()
        }
        .padding(.vertical, 2)
    }
}

private struct UsageBar: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(window.name).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: min(window.usedPercent, 100), total: 100)
                .progressViewStyle(.linear)
                .tint(window.usedPercent >= 100 ? .red : window.usedPercent >= 80 ? .orange : .accentColor)
                .frame(width: 70)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
        .help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }
}
