import AgTermCore
import SwiftUI

/// The team's shared Codex and Grok logins, with rename, pause and remove for whoever may change
/// them (the owner, or the manager who added one).
struct TeamLoginsPanel: View {
    @Environment(\.teams) private var c
    @ObservedObject var store: TeamDashboardStore
    @State private var renaming: TeamPool.Account?
    @State private var newName = ""
    @State private var removing: TeamPool.Account?
    @State private var busy: Set<String> = []
    @State private var error: String?

    var body: some View {
        let accounts = store.teamPool
        TeamsPanel(title: "Team logins", sub: "Codex and Grok logins the team shares") {
            if accounts.isEmpty {
                TeamsNote(store.team?.role.isAdmin == true
                          ? "No shared logins. Add one in Settings → Accounts with Add Team Account…"
                          : "Your team doesn't share any logins.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().overlay(c.border) }
                        row(account)
                    }
                }
                if !accounts.contains(where: \.canManage) {
                    TeamsNote("Only the team's owner, or the manager who added a login, can change it.")
                }
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(c.danger) }
        }
        .alert("Rename Login", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let account = renaming { rename(account) } }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Everyone on the team sees this name.")
        }
        .confirmationDialog("Remove \(removing?.label ?? "this login") from the team?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let account = removing { remove(account) } }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("agterm Teams deletes its copy of the login. Anyone using it now keeps it until their agent exits.")
        }
    }

    private func row(_ account: TeamPool.Account) -> some View {
        HStack(spacing: 10) {
            Circle().fill(c.provider(account.provider.rawValue)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(account.enabled ? c.fg : c.fg3)
                Text([account.provider.title, account.plan].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(c.fg3)
            }
            Spacer()
            Text(status(account)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(account.enabled ? c.fg2 : c.fg3)
            if busy.contains(account.id) {
                ProgressView().controlSize(.small).frame(width: 28)
            } else if account.canManage {
                Menu {
                    Button("Rename…") { newName = account.label; renaming = account }
                    Button(account.enabled ? "Pause" : "Resume") { setPaused(account, account.enabled) }
                    Divider()
                    Button("Remove…", role: .destructive) { removing = account }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Rename, pause or remove this login")
            }
        }
        .padding(.vertical, 8)
    }

    private func status(_ a: TeamPool.Account) -> String {
        let now = Date()
        if !a.enabled { return "Paused" }
        if a.leased(now) { return a.inUseMine ? "In use by you" : a.inUseBy.map { "In use by \($0)" } ?? "In use" }
        if a.exhausted(now) {
            return a.blockedUntil.map { "Out until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Out of usage"
        }
        if let left = a.shownRemaining(now) { return "\(Int(left.rounded()))% left" }
        return "Free"
    }

    private func run(_ account: TeamPool.Account, _ action: (@escaping (TeamPool.Failure?) -> Void) -> Void) {
        error = nil
        busy.insert(account.id)
        action { failure in
            busy.remove(account.id)
            error = failure?.message
        }
    }

    private func rename(_ account: TeamPool.Account) {
        let name = newName
        renaming = nil
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != account.label else { return }
        run(account) { TeamAccounts.shared.rename(account, to: name, completion: $0) }
    }

    private func setPaused(_ account: TeamPool.Account, _ paused: Bool) {
        run(account) { TeamAccounts.shared.setPaused(account, paused, completion: $0) }
    }

    private func remove(_ account: TeamPool.Account) {
        removing = nil
        run(account) { TeamAccounts.shared.remove(account, completion: $0) }
    }
}
