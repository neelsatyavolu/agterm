import SwiftUI

/// Team sessions: share this Mac's agent tabs with teammates' agents through agterm Teams.
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
                Toggle("Let my agents coordinate with my team's agents", isOn: Binding(
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
                    Your agents and the agents of teammates who turn this on share a board in each repo, where they \
                    claim work (a migration number, a file), ask everyone and record decisions, and they can see each \
                    other's agent tabs (title, folder name, branch, status). A teammate's agent can ask a read-only \
                    copy of one of your tabs a question; it runs on this Mac and reads only that tab's conversation \
                    (and, for Claude Code, files in its folder). Messages are typed into your agent as its next \
                    prompt, marked as coming from a teammate's agent.
                    """)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
