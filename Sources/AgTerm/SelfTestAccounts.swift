#if DEBUG
import AgTermCore
import AppKit
import SwiftUI

extension SelfTest {
    /// Use for New Sessions: `AGTERM_ACCOUNTS_CHECK=1 AGTERM_SELFTEST=<dir>`. Adds a stand-in Claude
    /// Code login with stubbed usage, snapshots Settings → Accounts before and after choosing it,
    /// and checks where new sessions would start as it runs out, switching is turned off and it's
    /// turned off for switching. Puts the account settings and routing back as they were.
    static func accountsCheck(outDir: String) {
        let store = AccountStore.shared, monitor = UsageMonitor.shared
        let saved = store.settings, savedRouting = AccountStore.loadRouting()
        let test = StoredAccount(id: "prefer-test", provider: .claude, label: "work@example.com", email: "work@example.com",
                                 plan: "Claude Max", enabled: true)
        func stub(_ provider: AccountProvider, _ id: String, used: Double) {
            monitor.stubs[UsageMonitor.key(provider, id)] = UsageReading(
                windows: [UsageWindow(name: "5-hour", usedPercent: used / 2, resetsAt: Date().addingTimeInterval(3600)),
                          UsageWindow(name: "Weekly", usedPercent: used, resetsAt: Date().addingTimeInterval(86_400))],
                checkedAt: Date())
            monitor.refresh(provider, id)
        }
        store.update { $0.autoSwitch = true; $0.accounts = [test]; $0.preferred = [:] }
        for provider in AccountProvider.allCases { stub(provider, AccountStore.native, used: 22) }
        stub(.claude, test.id, used: 40)

        // Self-tests run on the main thread.
        let host = MainActor.assumeIsolated {
            NSHostingView(rootView: AccountsPane(store: store, monitor: monitor, login: .shared, team: .shared, teams: .shared)
                .formStyle(.grouped).frame(width: 640, height: 720))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func snap(_ name: String) {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                host.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/accounts-\(name)-\(look).png"))
            }
        }
        func route() -> String { AccountStore.loadRouting().active["claude"] ?? "native" }
        func finish(_ code: Int32) {
            store.update { $0 = saved }
            AccountStore.saveRouting(savedRouting)
            exit(code)
        }

        after(1) {
            snap("default")
            let startsNative = route() == "native"
            print("selftest: accounts: starts on your login:", startsNative)
            store.prefer(test.id, provider: .claude)
            monitor.updateRouting(.claude)
            let chosen = route() == test.id
            print("selftest: accounts: chosen login routes new sessions:", chosen)
            after(0.5) {
                snap("chosen")
                stub(.claude, test.id, used: 100)
                let leftWhenOut = route() == "native"
                print("selftest: accounts: used up, new sessions go to your login:", leftWhenOut)
                store.update { $0.autoSwitch = false }
                monitor.updateRouting(.claude)
                let keptWithoutSwitching = store.settings.home(.claude) == test.id && route() == test.id
                print("selftest: accounts: switching off keeps the chosen login:", keptWithoutSwitching)
                store.update { $0.autoSwitch = true; $0.accounts[0].enabled = false }
                monitor.updateRouting(.claude)
                let disabledFallsBack = store.settings.home(.claude) == AccountStore.native
                print("selftest: accounts: turned off for switching, home is your login:", disabledFallsBack)
                store.prefer(test.id, provider: .claude)
                let reEnabled = store.settings.accounts.first?.enabled == true
                print("selftest: accounts: choosing it turns switching back on:", reEnabled)
                store.prefer(AccountStore.native, provider: .claude)
                let backToNative = store.settings.preferred.isEmpty
                print("selftest: accounts: choosing your login clears the choice:", backToNative)
                let ok = startsNative && chosen && leftWhenOut && keptWithoutSwitching && disabledFallsBack && reEnabled && backToNative
                finish(ok ? 0 : 2)
            }
        }
    }
}
#endif
