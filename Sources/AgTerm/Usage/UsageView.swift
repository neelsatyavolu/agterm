import AgTermCore
import SwiftUI

/// Theme colors for SwiftUI, read on every render so a theme change shows at once.
enum UsageInk {
    static var fg: Color { Color(nsColor: Theme.fg) }
    static var fg2: Color { Color(nsColor: Theme.fg2) }
    static var fg3: Color { Color(nsColor: Theme.fg3) }
    static var fg4: Color { Color(nsColor: Theme.fg4) }
    static var border: Color { Color(nsColor: Theme.border) }
    static var surface: Color { Color(nsColor: Theme.surface) }
    static var accent: Color { Color(nsColor: Theme.accent) }
    static var ok: Color { Color(nsColor: Theme.ok) }
    static var danger: Color { Color(nsColor: Theme.danger) }
    static var bg: Color { Color(nsColor: Theme.color(Theme.palette.bg)) }
}

/// Short figures for the Usage window.
enum UsageFormat {
    static func cost(_ totals: UsageTotals) -> String {
        UsageText.cost(totals.costUSD, incomplete: totals.costIncomplete) ?? (totals.costIncomplete ? "$0.00+" : "$0.00")
    }

    /// "38k", "1.2M", "0".
    static func tokens(_ count: Int) -> String {
        UsageText.tokens(count)?.replacingOccurrences(of: " tokens", with: "") ?? "0"
    }

    static func model(_ id: String) -> String { ModelName.short(id) ?? id }
}

struct UsageView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if firstRead {
                    reading
                } else {
                    tiles
                    UsageChart(days: model.report.days, period: model.period)
                    HStack(alignment: .top, spacing: 16) {
                        UsageRows(title: "Models", rows: summary.models, name: UsageFormat.model)
                        UsageRows(title: "Projects", rows: summary.projects, name: { $0 })
                    }
                }
                UsageLimits(monitor: monitor)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)
            // Child views don't take the theme as input; rebuild them all when it changes.
            .id(Theme.palette.id)
        }
        .background(UsageInk.bg)
    }

    private var summary: UsageSummary { model.report.summary(model.period) }

    /// No report yet and one being read: zeros here would read as "you used nothing".
    private var firstRead: Bool { model.scanning && model.updatedAt == nil }

    private var reading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading this Mac's Claude Code and Codex transcripts from the last 30 days. "
                 + "The first time takes a few seconds; after that only new sessions are read.")
                .font(.system(size: 12)).foregroundStyle(UsageInk.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(UsageInk.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UsageInk.border))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Usage").font(.system(size: 22, weight: .semibold)).foregroundStyle(UsageInk.fg)
                Spacer()
                Picker("Period", selection: $model.period) {
                    ForEach(UsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(status).font(.system(size: 11)).foregroundStyle(UsageInk.fg3).monospacedDigit()
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(UsageInk.fg2)
                .disabled(model.scanning)
                .help("Read the transcripts again and check every login's limits")
            }
            Text("Claude Code and Codex sessions on this Mac, estimated at API prices from local transcripts. Not your bill.")
                .font(.system(size: 12)).foregroundStyle(UsageInk.fg3)
        }
    }

    private var status: String {
        if model.scanning { return "Reading…" }
        return model.updatedAt.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }

    private var tiles: some View {
        let totals = summary.totals
        return HStack(spacing: 12) {
            UsageTile(label: "Estimated cost", value: UsageFormat.cost(totals), detail: model.period.title)
            UsageTile(label: "Tokens", value: UsageFormat.tokens(totals.tokens),
                      detail: "\(UsageFormat.tokens(totals.tokensIn)) in · \(UsageFormat.tokens(totals.tokensOut)) out · "
                          + "\(UsageFormat.tokens(totals.cacheRead + totals.cacheWrite)) cache")
            UsageTile(label: "Sessions", value: "\(totals.sessions)", detail: "Subagents not counted")
        }
    }
}

/// One figure with its label.
struct UsageTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(UsageInk.fg3)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(UsageInk.fg)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11)).foregroundStyle(UsageInk.fg3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(UsageInk.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UsageInk.border))
    }
}

/// A ranked list of models or projects: name, tokens, cost.
struct UsageRows: View {
    let title: String
    let rows: [UsageRow]
    let name: (String) -> String
    private static let limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(UsageInk.fg).padding(.bottom, 8)
            if rows.isEmpty {
                Text("Nothing in this period.").font(.system(size: 12)).foregroundStyle(UsageInk.fg3).padding(.vertical, 8)
            }
            ForEach(Array(rows.prefix(Self.limit).enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(UsageInk.border).frame(height: 1) }
                HStack(spacing: 8) {
                    Text(name(row.name)).font(.system(size: 12)).foregroundStyle(UsageInk.fg2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(UsageFormat.tokens(row.totals.tokens)).font(.system(size: 12).monospacedDigit()).foregroundStyle(UsageInk.fg3)
                    Text(UsageFormat.cost(row.totals)).font(.system(size: 12).monospacedDigit()).foregroundStyle(UsageInk.fg)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .padding(.vertical, 7)
            }
            if rows.count > Self.limit {
                Text("\(rows.count - Self.limit) more").font(.system(size: 11)).foregroundStyle(UsageInk.fg3).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
