import AgTermCore
import Foundation

/// Usage of every login, kept fresh while you have more than one, and which login new
/// sessions should start on.
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()
    /// Background refresh while you have extra logins. Each check is one short CLI run.
    static let interval: TimeInterval = 5 * 60

    @Published private(set) var readings: [String: UsageReading] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var checking: Set<String> = []
    /// Logins an agent just stopped on, until their limit resets.
    private var blocked: [String: Date] = [:]
    private var timer: Timer?

    static func key(_ provider: AccountProvider, _ id: String) -> String { provider.rawValue + ":" + id }

    func start() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard Self.switching else { return }
            self?.refreshAll()
            TeamAccounts.shared.refresh()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if Self.switching { refreshAll() }
    }

    /// There's somewhere to switch to: an added login, or your team's.
    private static var switching: Bool { !AccountStore.shared.settings.accounts.isEmpty || TeamAccounts.shared.isConnected }

    /// Your login first, then added ones, in the order they were added.
    func ids(_ provider: AccountProvider, enabledOnly: Bool = false) -> [String] {
        [AccountStore.native] + AccountStore.shared.accounts(provider).filter { !enabledOnly || $0.enabled }.map(\.id)
    }

    func reading(_ provider: AccountProvider, _ id: String) -> UsageReading? { readings[Self.key(provider, id)] }

    func refreshAll() {
        for provider in AccountProvider.allCases where QuickCommandRunner.shared.isReady ? QuickCommandRunner.shared.executable(provider.rawValue) != nil : true {
            for id in ids(provider) { refresh(provider, id) }
        }
    }

    #if DEBUG
    /// Self-test only: readings returned instead of asking the CLI.
    var stubs: [String: UsageReading] = [:]
    #endif

    /// Checks one login now; `completion` runs on the main queue.
    func refresh(_ provider: AccountProvider, _ id: String, completion: (() -> Void)? = nil) {
        let key = Self.key(provider, id)
        #if DEBUG
        if let stub = stubs[key] {
            readings[key] = stub
            errors[key] = nil
            updateRouting(provider)
            completion?()
            return
        }
        #endif
        checking.insert(key)
        let home = id == AccountStore.native ? nil : try? AccountStore.prepareHome(id, provider: provider)
        DispatchQueue.global(qos: .utility).async {
            let result = UsageProbe.read(provider, home: home)
            DispatchQueue.main.async {
                self.checking.remove(key)
                if let reading = result.reading {
                    self.readings[key] = reading
                    self.noteDetails(provider, id, reading)
                }
                self.errors[key] = result.error
                self.updateRouting(provider)
                completion?()
            }
        }
    }

    /// Checks several logins at once; `completion` runs once all are back.
    func refresh(_ provider: AccountProvider, _ ids: [String], completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for id in ids {
            group.enter()
            refresh(provider, id) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    /// An agent stopped at its limit on this login: keep new sessions off it until it resets.
    func markExhausted(_ provider: AccountProvider, _ id: String) {
        let until = reading(provider, id)?.exhaustedUntil(Date()) ?? Date().addingTimeInterval(15 * 60)
        blocked[Self.key(provider, id)] = until
        updateRouting(provider)
    }

    func candidates(_ provider: AccountProvider) -> [AccountPicker.Candidate] {
        ids(provider).map { id in
            let enabled = id == AccountStore.native || AccountStore.shared.account(id)?.enabled == true
            return AccountPicker.Candidate(id: id, enabled: enabled, reading: reading(provider, id),
                                           blockedUntil: blocked[Self.key(provider, id)], failed: errors[Self.key(provider, id)] != nil)
        }
    }

    /// New sessions start on your own login (or the one you chose) while it has usage, else on
    /// the login with the most left, else on one borrowed from your team.
    func updateRouting(_ provider: AccountProvider) {
        let settings = AccountStore.shared.settings
        let team = provider.teamShareable && TeamAccounts.shared.hasBorrowable(provider) ? AccountStore.teamRoute : nil
        let picked = AccountPicker.forNewSessions(candidates(provider), home: settings.home(provider),
                                                  autoSwitch: settings.autoSwitch, now: Date()) ?? team
        let next = picked == AccountStore.native ? nil : picked
        var routing = AccountStore.loadRouting()
        guard routing.active[provider.rawValue] != next else { return }
        routing.active[provider.rawValue] = next
        AccountStore.saveRouting(routing)
    }

    /// Keeps an added login's email and plan current in Settings.
    private func noteDetails(_ provider: AccountProvider, _ id: String, _ reading: UsageReading) {
        guard id != AccountStore.native, var account = AccountStore.shared.account(id) else { return }
        let plan = reading.plan ?? account.plan, email = reading.email ?? account.email
        guard plan != account.plan || email != account.email else { return }
        account.plan = plan
        account.email = email
        AccountStore.shared.add(account)
    }
}
