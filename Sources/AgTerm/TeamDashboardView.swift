import AgTermCore
import SwiftUI

/// The overview for owners and managers: headline numbers, daily usage, budget, provider and
/// model mix, members (click one for their detail), the team's shared logins and projects.
struct TeamDashboardView: View {
    @Environment(\.teams) private var c
    let overview: TeamDashboard.Overview
    @ObservedObject var store: TeamDashboardStore
    @State private var measure = TeamsDailyChart.Measure.tokens
    @State private var openMember: TeamDashboard.Member?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let neverSynced = overview.members.filter(\.neverSynced).count
            if neverSynced > 0 {
                TeamsBanner(text: neverSynced == 1 ? "1 member has never synced. Totals leave them out."
                                                   : "\(neverSynced) members have never synced. Totals leave them out.")
            }
            stats
            TeamsPanel(title: "Daily usage", sub: store.range.title, trailing: {
                Picker("", selection: $measure) {
                    ForEach(TeamsDailyChart.Measure.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }) {
                TeamsDailyChart(days: overview.daily, measure: measure)
            }
            if let budget = overview.budget { TeamsPanel(title: "Monthly budget", sub: "all providers") { BudgetView(budget: budget) } }
            HStack(alignment: .top, spacing: 12) {
                TeamsPanel(title: "Providers", sub: "share of tokens") { TeamsMixList(slices: overview.providerMix) }
                TeamsPanel(title: "Top models") { TeamsMixList(slices: Array(overview.modelMix.prefix(6)), models: true) }
            }
            TeamsPanel(title: "Members", sub: "click one for detail") {
                MemberTable(members: overview.members) { openMember = $0 }
            }
            TeamLoginsPanel(store: store)
            if !overview.projects.isEmpty {
                TeamsPanel(title: "Projects", sub: "folder name only") { ProjectTable(projects: Array(overview.projects.prefix(10))) }
            }
        }
        .sheet(item: $openMember) { member in
            TeamMemberSheet(member: member, store: store) { openMember = nil }
                .environment(\.teams, c)
        }
    }

    private var stats: some View {
        let t = overview.totals
        return HStack(spacing: 10) {
            TeamsStat(label: "Tokens", value: TeamDashboard.tokens(t.tokens), delta: TeamDashboard.delta(overview.deltas.tokens))
            TeamsStat(label: t.costIncomplete ? "Partial est. cost" : "Est. cost", value: TeamDashboard.money(t.costUsd),
                      note: "Estimate, not an invoice", delta: TeamDashboard.delta(overview.deltas.costUsd))
            TeamsStat(label: "Active", value: TeamDashboard.hours(t.activeHours), note: "agent working time",
                      delta: TeamDashboard.delta(overview.deltas.activeHours))
            TeamsStat(label: "Sessions", value: TeamDashboard.count(t.sessionsStarted),
                      note: "\(TeamDashboard.count(t.turns)) turns · \(TeamDashboard.count(t.toolCalls)) tool calls")
            TeamsStat(label: "Peak at once", value: TeamDashboard.count(t.peakConcurrent), note: "most sessions running together")
        }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Spend so far this month against the budget, with where the month is heading.
private struct BudgetView: View {
    @Environment(\.teams) private var c
    let budget: TeamDashboard.Budget

    var body: some View {
        let over = budget.usedShare >= 1
        let color = over ? c.danger : budget.onTrackToExceed ? c.danger.opacity(0.7) : c.accent
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(TeamDashboard.money(budget.spendUsd)).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(c.fg)
                Text("of \(TeamDashboard.money(budget.monthlyUsd)) this month").font(.system(size: 12)).foregroundStyle(c.fg3)
                Spacer()
                Text(TeamDashboard.percent(budget.usedShare)).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            }
            TeamsShareBar(share: budget.usedShare, color: color)
            HStack {
                Text("Day \(budget.daysElapsed) of \(budget.daysInMonth)")
                Spacer()
                Text("Projected \(TeamDashboard.money(budget.projectedUsd))")
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(c.fg3)
            if budget.onTrackToExceed {
                TeamsBanner(text: "At this pace the team ends the month at \(TeamDashboard.money(budget.projectedUsd)), over its \(TeamDashboard.money(budget.monthlyUsd)) budget.", warning: true)
            }
        }
    }
}

private struct MemberTable: View {
    @Environment(\.teams) private var c
    let members: [TeamDashboard.Member]
    let open: (TeamDashboard.Member) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            row(header: true, name: Text("Member"), cells: ["Active", "Tokens", "Est. cost", "Sessions", "Last seen"])
            ForEach(members) { member in
                Divider().overlay(c.border)
                Button { if !member.neverSynced { open(member) } } label: { memberRow(member) }
                    .buttonStyle(.plain)
                    .background(hovered == member.id && !member.neverSynced ? c.surface : .clear)
                    .onHover { hovered = $0 ? member.id : nil }
            }
        }
    }

    private func memberRow(_ m: TeamDashboard.Member) -> some View {
        let name = HStack(spacing: 6) {
            Text(m.displayName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(m.neverSynced ? c.fg3 : c.fg).lineLimit(1)
            if m.role != .employee { TeamsRoleBadge(role: m.role) }
        }
        let seen = TeamDashboard.ago(m.lastUploadAt) ?? "never"
        if m.neverSynced {
            return AnyView(HStack {
                name
                Spacer()
                Text("waiting for first sync").font(.system(size: 11)).foregroundStyle(c.fg3)
            }.padding(.vertical, 8).contentShape(Rectangle()))
        }
        let t = m.totals
        return AnyView(row(header: false, name: name, cells: [TeamDashboard.hours(t.activeHours), TeamDashboard.tokens(t.tokens),
                                                             TeamDashboard.money(t.costUsd), TeamDashboard.count(t.sessionsStarted), seen]))
    }

    private func row<Name: View>(header: Bool, name: Name, cells: [String]) -> some View {
        HStack(spacing: 0) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell).font(header ? .system(size: 11) : .system(size: 12).monospacedDigit())
                    .foregroundStyle(header ? c.fg3 : index == 0 ? c.fg : c.fg2).lineLimit(1)
                    .frame(width: index == cells.count - 1 ? 110 : 80, alignment: .trailing)
            }
        }
        .font(.system(size: 11)).foregroundStyle(c.fg3)
        .padding(.vertical, header ? 4 : 8)
        .contentShape(Rectangle())
    }
}

private struct ProjectTable: View {
    @Environment(\.teams) private var c
    let projects: [TeamDashboard.Project]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(projects) { p in
                HStack {
                    Text(p.projectKey).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(c.fg2).lineLimit(1)
                    Spacer()
                    Text(TeamDashboard.hours(p.activeHours)).frame(width: 70, alignment: .trailing).foregroundStyle(c.fg)
                    Text(TeamDashboard.tokens(p.tokens)).frame(width: 70, alignment: .trailing).foregroundStyle(c.fg2)
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
    }
}
