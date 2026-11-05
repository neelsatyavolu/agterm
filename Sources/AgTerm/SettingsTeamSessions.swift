import SwiftUI

/// Team sessions: share this Mac's agent tabs with teammates' agents through agmux Teams.
struct TeamSessionsSection: View {
    @ObservedObject var account: TeamsAccount
    @ObservedObject var sessions: TeamSessions

    var body: some View {
        if account.isSignedIn {
            Section {
                if sessions.teams.count > 1 {
                    Picker("Team", selection: Binding(get: { sessions.teamID ?? "" }, set: { sessions.choose(team: $0) })) {
                        ForEach(sessions.teams) { Text($0.name).tag($0.id) }
                    }
                }
                Toggle("Share my agent tabs with my team", isOn: Binding(
                    get: { sessions.enabled },
                    set: { sessions.setSharing(enabled: $0, acceptMessages: false) }))
                    .disabled(sessions.teamID == nil)
                Toggle("Let teammates' agents message my agents", isOn: Binding(
                    get: { sessions.acceptMessages },
                    set: { sessions.setSharing(enabled: true, acceptMessages: $0) }))
                    .disabled(!sessions.enabled)
                if let error = sessions.lastError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("Team Sessions")
            } footer: {
                Text("""
                    Teammates who also turn this on see each agent tab's title, folder name, branch and status, and \
                    their agents can ask a read-only copy of a Claude Code tab a question. The copy runs on this Mac \
                    and can answer from anything that tab has seen and from files in its folder. Messages are typed \
                    into the tab's agent as its next prompt, marked as coming from a teammate. Your agents get the \
                    same tools for your teammates' tabs.
                    """)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
