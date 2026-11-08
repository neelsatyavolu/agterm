#if DEBUG
import AgTermCore
import AppKit
import SwiftUI

extension SelfTest {
    /// The Team Dashboard window: `AGTERM_TEAMS_CHECK=1 AGTERM_SELFTEST=<dir>`. Fills it from
    /// fixtures shaped like teams-service replies (no network) and snapshots the full dashboard,
    /// a member's detail, the employee, waiting, offline, no-team and signed-out states, in Ink
    /// and Paper (`teams-<state>-<theme>.png`).
    @MainActor static func teamsCheck(outDir: String) {
        let store = TeamDashboardStore.shared
        let fixtures = TeamsFixtures()
        print("selftest: teams: overview decodes:", fixtures.overview.members.count == 5, fixtures.overview.state == .full)
        print("selftest: teams: pool decodes:", fixtures.pool.count == 3, fixtures.pool.filter(\.canManage).count == 2)
        print("selftest: teams: detail has logins:", fixtures.detail.logins?.rows.count == 3)
        let original = Preferences.shared.appearance.themeID

        let controller = TeamsWindowController.shared
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 1000, height: 1460))
        controller.showWindow(nil)

        let detailHost = NSHostingView(rootView: AnyView(EmptyView()))
        let detailWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        detailWindow.contentView = detailHost

        func full() { store.show(teams: fixtures.teams, overview: fixtures.overview, details: ["u1": fixtures.detail], pool: fixtures.pool) }
        let states: [(String, CGFloat, () -> Void)] = [
            ("full", 1460, full),
            ("self", 900, { store.show(teams: [fixtures.teams[1]], overview: fixtures.selfOverview, me: fixtures.detail) }),
            ("waiting", 620, { store.show(teams: fixtures.teams, overview: fixtures.waiting, pool: fixtures.pool) }),
            ("offline", 520, {
                store.show(teams: fixtures.teams, overview: fixtures.overview, pool: fixtures.pool, failure: .offline,
                           fetchedAt: Date().addingTimeInterval(-3 * 3600))
            }),
            ("offline-empty", 420, { store.show(teams: [], overview: nil, failure: .offline, loaded: false) }),
            ("no-team", 420, { store.show(teams: [], overview: nil) }),
            ("signed-out", 420, { store.show(teams: [], overview: nil, signedIn: false) }),
        ]

        func shoot(_ theme: String, _ done: @escaping () -> Void) {
            Preferences.shared.update { $0.themeID = theme }
            func step(_ index: Int) {
                guard index < states.count else {
                    full()
                    detailHost.rootView = AnyView(TeamMemberSheet(member: fixtures.overview.members[0], store: store) {}
                        .environment(\.teams, TeamsColors(palette: Preferences.shared.appearance.theme)))
                    detailWindow.appearance = NSAppearance(named: Preferences.shared.appearance.theme.isDark ? .darkAqua : .aqua)
                    after(0.8) {
                        snapshot(detailWindow, "\(outDir)/teams-member-\(theme).png")
                        done()
                    }
                    return
                }
                let (name, height, setUp) = states[index]
                setUp()
                window.setContentSize(NSSize(width: 1000, height: height))
                after(0.6) {
                    snapshot(window, "\(outDir)/teams-\(name)-\(theme).png")
                    step(index + 1)
                }
            }
            step(0)
        }

        after(0.5) {
            shoot("ink") {
                shoot("paper") {
                    print("selftest: teams: snapshots written:", FileManager.default.fileExists(atPath: "\(outDir)/teams-member-paper.png"))
                    Preferences.shared.update { $0.themeID = original }
                    exit(0)
                }
            }
        }
    }
}

/// Replies shaped like teams-service's dashboard and provider-accounts routes.
private struct TeamsFixtures {
    let teams: [TeamDashboard.Team]
    let overview: TeamDashboard.Overview
    let selfOverview: TeamDashboard.Overview
    let waiting: TeamDashboard.Overview
    let detail: TeamDashboard.MemberDetail
    let pool: [TeamPool.Account]

    init() {
        func decode<T: Decodable>(_ data: Any) -> T {
            let body = try! JSONSerialization.data(withJSONObject: ["ok": true, "data": data])
            return try! TeamDashboard.unwrap(status: 200, body: body)
        }
        func totals(_ scale: Double) -> [String: Any] {
            ["tokens": 41_000_000 * scale, "tokensIn": 3_000_000 * scale, "tokensOut": 900_000 * scale,
             "tokensCacheRead": 36_000_000 * scale, "costUsd": 312.4 * scale, "costIncomplete": false,
             "activeHours": 96.5 * scale, "sessions": 410 * scale, "sessionsStarted": 128 * scale, "turns": 5200 * scale,
             "toolCalls": 14_800 * scale, "peakConcurrent": max(1, (7 * scale).rounded()), "daysWithData": 24]
        }
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let daily: [[String: Any]] = (0..<30).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            let wave = 0.6 + 0.4 * sin(Double(back) / 3)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let label = DateFormatter()
            label.dateFormat = "M/d"
            return ["date": f.string(from: day), "label": label.string(from: day), "full": "", "weekend": weekend, "hasData": true,
                    "tokens": (weekend ? 0.3 : 1) * wave * 2_000_000, "activeHours": (weekend ? 0.3 : 1) * wave * 5,
                    "sessions": (weekend ? 0.3 : 1) * wave * 18, "peakConcurrent": 3]
        }
        func member(_ id: String, _ name: String, _ role: String, _ scale: Double?) -> [String: Any] {
            ["userId": id, "displayName": name, "role": role, "neverSynced": scale == nil,
             "lastUploadAt": scale == nil ? NSNull() : ISO8601DateFormatter().string(from: today.addingTimeInterval(-Double(id.count) * 1800)),
             "totals": scale.map(totals) ?? [:]]
        }
        let mix: [[String: Any]] = [["key": "claude", "tokens": 29_000_000, "share": 0.71, "timeShare": 0.66],
                                    ["key": "codex", "tokens": 10_500_000, "share": 0.26, "timeShare": 0.3],
                                    ["key": "grok", "tokens": 1_500_000, "share": 0.03, "timeShare": 0.04]]
        let models: [[String: Any]] = [["key": "claude-opus-4-5", "tokens": 22_000_000, "share": 0.54],
                                       ["key": "gpt-5.1-codex", "tokens": 10_500_000, "share": 0.26],
                                       ["key": "claude-sonnet-4-5", "tokens": 7_000_000, "share": 0.17]]
        teams = (decode(["teams": [["id": "t1", "slug": "nenu", "name": "Nenu", "role": "owner", "member_count": 5],
                                   ["id": "t2", "slug": "peek", "name": "Peek Labs", "role": "employee", "member_count": 12]]])
                 as TeamDashboard.TeamList).teams
        overview = decode([
            "range": "30d", "scope": "team", "role": "owner", "totals": totals(1),
            "deltas": ["tokens": 0.18, "costUsd": 0.22, "activeHours": -0.04],
            "daily": daily, "providerMix": mix, "modelMix": models,
            "projects": [["projectKey": "agterm", "activeHours": 51, "tokens": 22_000_000],
                         ["projectKey": "teams-service", "activeHours": 30.5, "tokens": 14_000_000],
                         ["projectKey": "site", "activeHours": 15, "tokens": 5_000_000]],
            "budget": ["month": "2026-11", "monthlyUsd": 400, "spendUsd": 312.4, "usedShare": 0.78, "projectedUsd": 1171,
                       "projectedShare": 2.9, "daysElapsed": 8, "daysInMonth": 30, "onTrackToExceed": true, "costIncomplete": false],
            "members": [member("u1", "Ada Lovelace", "owner", 0.45), member("u22", "Grace Hopper", "manager", 0.3),
                        member("u333", "Linus", "employee", 0.18), member("u4444", "Margaret", "employee", 0.07),
                        member("u5", "Alan", "employee", nil)],
            "memberCount": 5, "teamMemberCount": 5,
            "lastUploadAt": ISO8601DateFormatter().string(from: today.addingTimeInterval(-600)),
        ])
        selfOverview = decode(["scope": "self", "role": "employee", "totals": ["daysWithData": 6], "members": []])
        waiting = decode(["scope": "team", "role": "owner", "totals": [:], "memberCount": 3,
                          "members": [member("u1", "Ada Lovelace", "owner", nil), member("u5", "Alan", "employee", nil)]])
        detail = decode([
            "isSelf": false, "member": ["user_id": "u1", "display_name": "Ada Lovelace", "role": "owner"],
            "totals": totals(0.45), "daily": daily, "providerMix": mix,
            "logins": ["reported": true, "rows": [
                ["provider": "claude", "identityHash": "a1", "name": "ada@nenu.co", "tokens": 12_000_000, "costUsd": 88.1, "share": 0.65],
                ["provider": "codex", "identityHash": "b2", "name": "Team Codex Pro", "tokens": 5_400_000, "costUsd": 41.3, "share": 0.29],
                ["provider": "claude", "name": "Not attributed", "tokens": 1_100_000, "costUsd": 7.2, "share": 0.06],
            ]],
        ])
        let now = Date().timeIntervalSince1970
        let rows: [[String: Any]] = [
            ["id": "p1", "provider": "codex", "label": "Team Codex Pro", "enabled": true, "canManage": true, "plan": "Pro",
             "remainingPercent": 62, "healthReportedAt": now - 60],
            ["id": "p2", "provider": "codex", "label": "Codex Plus (spare)", "enabled": true, "canManage": false,
             "leasedUntil": now + 200, "inUse": ["self": false, "by": "Grace Hopper", "kind": "session"]],
            ["id": "p3", "provider": "grok", "label": "Grok Heavy", "enabled": false, "canManage": true, "plan": "SuperGrok"],
        ]
        let body = try! JSONSerialization.data(withJSONObject: ["ok": true, "data": ["accounts": rows]])
        pool = (try? TeamPool.accounts(status: 200, body: body, team: TeamPool.Team(id: "t1", name: "Nenu", canAdd: true))) ?? nil ?? []
    }
}
#endif
