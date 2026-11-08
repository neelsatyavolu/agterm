import AgTermCore
import SwiftUI

/// One member's numbers for the range: totals, daily usage, which Claude or Codex login did the
/// work, and providers. Also what an employee sees of themselves.
struct TeamMemberDetailContent: View {
    @Environment(\.teams) private var c
    let detail: TeamDashboard.MemberDetail
    let range: TeamDashboard.Range
    @State private var measure = TeamsDailyChart.Measure.tokens

    var body: some View {
        let t = detail.totals
        VStack(alignment: .leading, spacing: 12) {
            if detail.neverSynced {
                TeamsBanner(text: "No usage uploaded yet. Numbers appear after this member's app syncs.")
            }
            HStack(spacing: 10) {
                TeamsStat(label: "Tokens", value: TeamDashboard.tokens(t.tokens))
                TeamsStat(label: t.costIncomplete ? "Partial est. cost" : "Est. cost", value: TeamDashboard.money(t.costUsd))
                TeamsStat(label: "Active", value: TeamDashboard.hours(t.activeHours))
                TeamsStat(label: "Sessions", value: TeamDashboard.count(t.sessionsStarted), note: "\(TeamDashboard.count(t.turns)) turns")
            }
            .fixedSize(horizontal: false, vertical: true)
            if !detail.daily.isEmpty {
                TeamsPanel(title: "Daily usage", sub: range.title, trailing: {
                    Picker("", selection: $measure) {
                        ForEach(TeamsDailyChart.Measure.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }) {
                    TeamsDailyChart(days: detail.daily, measure: measure)
                }
            }
            TeamsPanel(title: "Usage by login", sub: "which Claude or Codex login did the work") { LoginUsage(logins: detail.logins) }
            TeamsPanel(title: "Providers", sub: "share of tokens") { TeamsMixList(slices: detail.providerMix) }
        }
    }
}

/// The member's usage split by login, as agmux's LoginsPanel shows it.
private struct LoginUsage: View {
    @Environment(\.teams) private var c
    let logins: TeamDashboard.Logins?

    var body: some View {
        if let logins {
            if !logins.reported {
                TeamsNote("Not reported yet. Logins appear after this member's app next syncs, for sessions started from then on.")
            } else if logins.rows.isEmpty {
                TeamsNote("No Claude or Codex usage in this range.")
            } else {
                VStack(spacing: 8) {
                    ForEach(logins.rows) { row in
                        let unattributed = row.identityHash == nil
                        HStack(spacing: 10) {
                            Circle().fill(c.provider(row.provider)).frame(width: 8, height: 8)
                            Text(row.name).font(.system(size: 12)).foregroundStyle(unattributed ? c.fg3 : c.fg2).lineLimit(1)
                                .frame(width: 190, alignment: .leading)
                            TeamsShareBar(share: row.share ?? 0, color: c.provider(row.provider).opacity(unattributed ? 0.35 : 1))
                            Text(row.share.map(TeamDashboard.percent) ?? "—").frame(width: 38, alignment: .trailing).foregroundStyle(c.fg3)
                            Text(TeamDashboard.tokens(row.tokens)).frame(width: 52, alignment: .trailing).foregroundStyle(c.fg3)
                            Text(TeamDashboard.money(row.costUsd)).frame(width: 64, alignment: .trailing).foregroundStyle(c.fg2)
                        }
                        .font(.system(size: 11.5).monospacedDigit())
                        .help("\(TeamDashboard.providerName(row.provider)): \(row.name)")
                    }
                }
            }
        } else {
            TeamsNote("This agterm Teams server doesn't report usage by login yet.")
        }
    }
}

/// A member's detail over the dashboard, fetched when opened.
struct TeamMemberSheet: View {
    @Environment(\.teams) private var c
    let member: TeamDashboard.Member
    @ObservedObject var store: TeamDashboardStore
    let close: () -> Void
    @State private var result: Result<TeamDashboard.MemberDetail, TeamDashboard.Failure>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(member.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(c.fg)
                TeamsRoleBadge(role: member.role)
                if let seen = TeamDashboard.ago(member.lastUploadAt) {
                    Text("last synced \(seen)").font(.system(size: 11.5)).foregroundStyle(c.fg3)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                switch result {
                case .none:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
                case .success(let detail)?:
                    TeamMemberDetailContent(detail: detail, range: store.range)
                case .failure(let failure)?:
                    TeamsEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load \(member.displayName)",
                                    message: failure.localizedDescription)
                }
            }
        }
        .padding(18)
        .frame(width: 760, height: 620)
        .background(c.bg)
        .environment(\.colorScheme, c.colorScheme)
        .task { result = await store.detail(member.userId) }
    }
}
