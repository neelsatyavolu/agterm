import AgTermCore
import AppKit
import Charts
import SwiftUI

/// The Teams window's colors, from the current theme (solid: the window ignores see-through settings).
struct TeamsColors {
    let palette: ThemePalette

    var bg: Color { color(palette.bg) }
    var fg: Color { color(palette.fg) }
    var fg2: Color { color(palette.fg, 0.68) }
    var fg3: Color { color(palette.fg, 0.45) }
    var surface: Color { color(palette.fg, 0.035) }
    var border: Color { color(palette.fg, 0.10) }
    var track: Color { color(palette.fg, 0.07) }
    var accent: Color { color(palette.accent) }
    var ok: Color { color(palette.ok) }
    var danger: Color { color(palette.danger) }
    var colorScheme: ColorScheme { palette.isDark ? .dark : .light }

    /// Claude in the accent, the others in the theme's other two signal colors.
    func provider(_ key: String) -> Color {
        switch key.lowercased() {
        case "claude": accent
        case "codex": ok
        case "grok": danger
        default: fg3
        }
    }

    private func color(_ rgb: RGB, _ alpha: CGFloat = 1) -> Color { Color(nsColor: Theme.color(rgb, alpha: alpha)) }
}

private struct TeamsColorsKey: EnvironmentKey {
    static let defaultValue = TeamsColors(palette: ThemeCatalog.named(ThemeCatalog.defaultID))
}

extension EnvironmentValues {
    var teams: TeamsColors {
        get { self[TeamsColorsKey.self] }
        set { self[TeamsColorsKey.self] = newValue }
    }
}

/// A titled box with a hairline border.
struct TeamsPanel<Content: View, Trailing: View>: View {
    @Environment(\.teams) private var c
    let title: String
    var sub: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.fg)
                if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(c.fg3) }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(c.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c.border, lineWidth: 1))
    }
}

extension TeamsPanel where Trailing == EmptyView {
    init(title: String, sub: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, sub: sub, trailing: { EmptyView() }, content: content)
    }
}

/// One headline number.
struct TeamsStat: View {
    @Environment(\.teams) private var c
    let label: String
    let value: String
    var note: String?
    var delta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(c.fg3).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(c.fg)
                if let delta { Text(delta).font(.system(size: 11).monospacedDigit()).foregroundStyle(c.fg3) }
            }
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(c.fg3).lineLimit(2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(c.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c.border, lineWidth: 1))
    }
}

/// A thin bar showing `share` (0–1) of its width.
struct TeamsShareBar: View {
    @Environment(\.teams) private var c
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(c.track)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 6)
    }
}

/// Providers or models by share of tokens.
struct TeamsMixList: View {
    @Environment(\.teams) private var c
    let slices: [TeamDashboard.Mix]
    var models = false

    var body: some View {
        if slices.isEmpty {
            TeamsNote("Nothing in this range.")
        } else {
            VStack(spacing: 8) {
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        Text(models ? slice.key : TeamDashboard.providerName(slice.key))
                            .font(models ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                            .foregroundStyle(c.fg2).lineLimit(1).frame(width: 150, alignment: .leading)
                        TeamsShareBar(share: slice.share, color: models ? c.fg3 : c.provider(slice.key))
                        Text(TeamDashboard.percent(slice.share)).font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(c.fg3).frame(width: 38, alignment: .trailing)
                        Text(TeamDashboard.tokens(slice.tokens)).font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(c.fg3).frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Daily bars for one measure.
struct TeamsDailyChart: View {
    enum Measure: String, CaseIterable, Identifiable {
        case tokens = "Tokens", hours = "Active hours", sessions = "Session-hours"
        var id: String { rawValue }

        func value(_ day: TeamDashboard.Day) -> Double {
            switch self {
            case .tokens: day.tokens
            case .hours: day.activeHours
            case .sessions: day.sessions
            }
        }
    }

    @Environment(\.teams) private var c
    let days: [TeamDashboard.Day]
    let measure: Measure

    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Day", day.date), y: .value(measure.rawValue, measure.value(day)))
                .foregroundStyle(day.weekend ? c.accent.opacity(0.5) : c.accent)
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel {
                    if let date = value.as(String.self) { Text(label(date)).font(.system(size: 10)).foregroundStyle(c.fg3) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(c.border)
                AxisValueLabel {
                    if let n = value.as(Double.self) {
                        Text(measure == .tokens ? TeamDashboard.tokens(n) : TeamDashboard.count(n))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(c.fg3)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    /// About six labels across, whatever the range.
    private var axisDates: [String] {
        let step = max(1, days.count / 6)
        // Not the first day: its label would be clipped at the edge.
        return days.enumerated().filter { $0.offset > 0 && $0.offset % step == 0 }.map(\.element.date)
    }

    private func label(_ date: String) -> String { days.first { $0.date == date }?.label ?? date }
}

/// A short line of muted text.
struct TeamsNote: View {
    @Environment(\.teams) private var c
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(c.fg3).fixedSize(horizontal: false, vertical: true)
    }
}

/// Owner, Manager, Employee.
struct TeamsRoleBadge: View {
    @Environment(\.teams) private var c
    let role: TeamDashboard.Role

    var body: some View {
        Text(role.title).font(.system(size: 10, weight: .medium)).foregroundStyle(role == .owner ? c.accent : c.fg2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(role == .owner ? c.accent.opacity(0.5) : c.border, lineWidth: 1))
    }
}

/// A notice above the content.
struct TeamsBanner: View {
    @Environment(\.teams) private var c
    let text: String
    var warning = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle").foregroundStyle(warning ? c.danger : c.fg3)
            Text(text).font(.system(size: 12)).foregroundStyle(c.fg2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(warning ? c.danger.opacity(0.08) : c.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(warning ? c.danger.opacity(0.3) : c.border, lineWidth: 1))
    }
}

/// A centered message with an optional button, for states with nothing to chart.
struct TeamsEmptyState: View {
    @Environment(\.teams) private var c
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(c.fg3)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(c.fg)
            Text(message).font(.system(size: 12.5)).foregroundStyle(c.fg2).multilineTextAlignment(.center)
                .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.title, action: action.run).padding(.top, 4) }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

extension TeamDashboard {
    /// "5 min ago" for the service's timestamps.
    static func ago(_ raw: String?) -> String? {
        date(raw).map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
    }
}
