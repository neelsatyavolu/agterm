import AgTermCore
import SwiftUI

/// Estimated cost per day for the last 30 days. Days in the chosen period are solid; hovering a
/// bar shows its day, cost and tokens.
struct UsageChart: View {
    let days: [UsageDay]
    let period: UsagePeriod
    @State private var hovered: Int?
    private static let height: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 30 days").font(.system(size: 13, weight: .semibold)).foregroundStyle(UsageInk.fg)
                Spacer()
                Text(readout).font(.system(size: 12).monospacedDigit()).foregroundStyle(UsageInk.fg3)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    bar(index, day)
                }
            }
            .frame(height: Self.height, alignment: .bottom)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(UsageInk.border).frame(height: 1) }
        }
    }

    /// Bars follow cost; with no prices at all, they follow tokens.
    private var byCost: Bool { days.contains { $0.totals.costUSD > 0 } }

    private func value(_ day: UsageDay) -> Double { byCost ? day.totals.costUSD : Double(day.totals.tokens) }

    private func bar(_ index: Int, _ day: UsageDay) -> some View {
        let peak = days.map(value).max() ?? 0
        let share = peak > 0 ? value(day) / peak : 0
        let inPeriod = index >= days.count - period.days
        let color = inPeriod ? UsageInk.accent : UsageInk.accent.opacity(0.35)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2)
                .fill(hovered == index ? UsageInk.fg : color)
                .frame(height: max(share * Self.height, value(day) > 0 ? 2 : 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
        .help(describe(day))
    }

    private var readout: String {
        if let hovered, days.indices.contains(hovered) { return describe(days[hovered]) }
        return "Hover a day for its total"
    }

    private func describe(_ day: UsageDay) -> String {
        let date = day.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(date) · \(UsageFormat.cost(day.totals)) · \(UsageFormat.tokens(day.totals.tokens)) tokens"
    }
}

/// Each login's limit windows, as last read from its CLI.
struct UsageLimits: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Limits").font(.system(size: 13, weight: .semibold)).foregroundStyle(UsageInk.fg).padding(.bottom, 8)
            if logins.isEmpty {
                Text("No limits read yet. agterm asks each agent CLI you're signed in to when this window opens.")
                    .font(.system(size: 12)).foregroundStyle(UsageInk.fg3)
            }
            ForEach(Array(logins.enumerated()), id: \.element.key) { index, login in
                if index > 0 { Rectangle().fill(UsageInk.border).frame(height: 1) }
                row(login)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Login {
        let provider: AccountProvider
        let id: String
        var key: String { UsageMonitor.key(provider, id) }
    }

    /// Logins with something to show: a reading, a check under way, or an error.
    private var logins: [Login] {
        AccountProvider.allCases.flatMap { provider in
            monitor.ids(provider).map { Login(provider: provider, id: $0) }
        }.filter { monitor.readings[$0.key] != nil || monitor.checking.contains($0.key) || monitor.errors[$0.key] != nil }
    }

    private func row(_ login: Login) -> some View {
        let reading = monitor.readings[login.key]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(login.provider.title).font(.system(size: 12, weight: .medium)).foregroundStyle(UsageInk.fg)
                Text(title(login, reading)).font(.system(size: 12)).foregroundStyle(UsageInk.fg3).lineLimit(1)
                Spacer()
                if monitor.checking.contains(login.key) {
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(UsageInk.fg3)
                }
            }
            if let error = monitor.errors[login.key] {
                Text(error).font(.system(size: 11)).foregroundStyle(UsageInk.danger).lineLimit(2)
            }
            ForEach(reading?.windows ?? [], id: \.name) { window in
                UsageLimitBar(window: window, extended: reading?.hasCredits == true)
            }
        }
        .padding(.vertical, 10)
    }

    private func title(_ login: Login, _ reading: UsageReading?) -> String {
        let name = login.id == AccountStore.native ? (reading?.email ?? "your login") : AccountStore.shared.label(login.id, provider: login.provider)
        return [name, reading?.plan].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One limit window: how much is used and when it resets.
struct UsageLimitBar: View {
    let window: UsageWindow
    /// Paid credits keep the login going past this limit.
    let extended: Bool

    var body: some View {
        let used = min(max(window.usedPercent, 0), 100)
        HStack(spacing: 10) {
            Text(window.name).font(.system(size: 11)).foregroundStyle(UsageInk.fg2).frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageInk.surface)
                    Capsule().fill(used >= 100 && !extended ? UsageInk.danger : (used >= 80 ? UsageInk.fg2 : UsageInk.accent))
                        .frame(width: geo.size.width * used / 100)
                }
            }
            .frame(height: 6)
            .overlay(Capsule().strokeBorder(UsageInk.border))
            Text("\(Int(used.rounded()))% used").font(.system(size: 11).monospacedDigit()).foregroundStyle(UsageInk.fg2)
                .frame(width: 64, alignment: .trailing)
            Text(reset).font(.system(size: 11)).foregroundStyle(UsageInk.fg3).frame(width: 120, alignment: .trailing)
        }
    }

    private var reset: String {
        guard let at = window.resetsAt else { return "" }
        let left = at.timeIntervalSinceNow
        if left <= 0 { return "Reset" }
        if left < 86400 { return "Resets in " + UsageText.elapsed(left) }
        return "Resets " + at.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
