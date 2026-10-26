import AgTermCore
import AppKit

extension Notification.Name {
    /// Opens a tab and types `userInfo["command"]` at its first prompt.
    static let agtermOpenTab = Notification.Name("agterm.openTab")
}

/// Adding a login: its CLI's own sign-in runs in a new tab, pointed at a fresh folder, and
/// agterm watches that folder until the sign-in shows up. A login for a team goes to agmux
/// Teams, and agterm deletes its own copy: two copies would each renew the tokens and sign
/// each other out.
final class AccountLogin: ObservableObject {
    static let shared = AccountLogin()
    static let timeout: TimeInterval = 10 * 60

    /// A sign-in under way for a team's pool.
    struct TeamJob: Equatable {
        let id: String
        let provider: AccountProvider
        let team: TeamPool.Team
    }

    @Published private(set) var pending: [AccountProvider: String] = [:]
    @Published private(set) var message: [AccountProvider: String] = [:]
    @Published private(set) var teamJob: TeamJob?
    @Published private(set) var teamMessage: String?

    func start(_ provider: AccountProvider) {
        guard pending[provider] == nil, let (id, home) = open(provider, report: { self.message[provider] = $0 }) else { return }
        pending[provider] = id
        message[provider] = "Sign in in the new tab. Use the account you want to add, not your current one."
        watch(provider, id: id, home: home, until: Date().addingTimeInterval(Self.timeout))
    }

    /// Signs in a login for `team`'s pool.
    func start(_ provider: AccountProvider, team: TeamPool.Team) {
        guard teamJob == nil, provider.teamShareable, let (id, home) = open(provider, report: { self.teamMessage = $0 }) else { return }
        teamJob = TeamJob(id: id, provider: provider, team: team)
        teamMessage = "Sign in in the new tab with the \(provider.title) account to share with \(team.name)."
        watchTeam(id: id, home: home, until: Date().addingTimeInterval(Self.timeout))
    }

    /// Makes a fresh folder and runs the CLI's sign-in in a new tab, pointed at it.
    private func open(_ provider: AccountProvider, report: (String) -> Void) -> (String, URL)? {
        guard let cli = QuickCommandRunner.shared.executable(provider.rawValue) else {
            report("\(provider.title) isn't installed.")
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let home: URL
        do { home = try AccountStore.prepareHome(id, provider: provider) } catch {
            report("Couldn't create a folder for the account: \(error.localizedDescription)")
            return nil
        }
        let login: [String]
        switch provider {
        case .claude: login = ["auth", "login", "--claudeai"]
        case .codex: login = ["login", "-c", #"cli_auth_credentials_store="file""#]
        case .grok: login = ["login", "--oauth", "--leader-socket", AccountStore.grokLeaderSocket(home)]
        }
        let command = (["\(provider.homeVariable)=\(ShellEscape.path(home.path))", ShellEscape.path(cli)] + login.map(ShellEscape.path))
            .joined(separator: " ")
        NotificationCenter.default.post(name: .agtermOpenTab, object: nil, userInfo: ["command": command])
        return (id, home)
    }

    func cancel(_ provider: AccountProvider) {
        guard let id = pending.removeValue(forKey: provider) else { return }
        message[provider] = nil
        AccountStore.deleteHome(id, provider: provider)
    }

    func cancelTeam() {
        guard let job = teamJob else { return }
        teamJob = nil
        teamMessage = nil
        AccountStore.deleteHome(job.id, provider: job.provider)
    }

    private func watch(_ provider: AccountProvider, id: String, home: URL, until deadline: Date) {
        guard pending[provider] == id else { return }
        guard Date() < deadline else {
            cancel(provider)
            message[provider] = "The sign-in didn't finish within 10 minutes."
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let result = UsageProbe.read(provider, home: home)
            DispatchQueue.main.async {
                guard self.pending[provider] == id else { return }
                guard result.signedIn, let reading = result.reading else {
                    return self.watch(provider, id: id, home: home, until: deadline)
                }
                self.finish(provider, id: id, reading: reading)
            }
        }
    }

    private func watchTeam(id: String, home: URL, until deadline: Date) {
        guard let job = teamJob, job.id == id else { return }
        guard Date() < deadline else {
            cancelTeam()
            teamMessage = "The sign-in didn't finish within 10 minutes."
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let result = UsageProbe.read(job.provider, home: home)
            let credentials = result.signedIn ? FileManager.default.contents(atPath: home.appendingPathComponent("auth.json").path) : nil
            DispatchQueue.main.async {
                guard self.teamJob == job else { return }
                guard let credentials else { return self.watchTeam(id: id, home: home, until: deadline) }
                let label = result.reading?.email ?? "\(job.provider.title) account"
                self.teamMessage = "Adding \(label) to \(job.team.name)…"
                TeamAccounts.shared.upload(job.provider, team: job.team, label: label, credentials: credentials) { outcome in
                    // Cancelled while it was being sent: it may have gone through all the same.
                    guard self.teamJob == job || self.teamJob == nil else { return }
                    self.teamJob = nil
                    // The copy goes either way: after an upload it would be a second holder of the
                    // tokens and sign the team's out; after a failure, nothing here would use it.
                    AccountStore.deleteHome(id, provider: job.provider)
                    switch outcome {
                    case .success(let account): self.teamMessage = "Added \(account.label) to \(job.team.name)."
                    case .failure(let failure):
                        self.teamMessage = "Couldn't add it to \(job.team.name): \(failure.message) Add it again to retry."
                    }
                }
            }
        }
    }

    private func finish(_ provider: AccountProvider, id: String, reading: UsageReading, checkedNative: Bool = false) {
        let monitor = UsageMonitor.shared
        // Your own login's email is needed to spot a sign-in to the same account.
        guard checkedNative || monitor.reading(provider, AccountStore.native) != nil else {
            return monitor.refresh(provider, AccountStore.native) { [weak self] in
                self?.finish(provider, id: id, reading: reading, checkedNative: true)
            }
        }
        pending[provider] = nil
        let store = AccountStore.shared
        let email = reading.email?.lowercased()
        let nativeEmail = UsageMonitor.shared.reading(provider, AccountStore.native)?.email?.lowercased()
        if let email, email == nativeEmail || store.accounts(provider).contains(where: { $0.email?.lowercased() == email }) {
            message[provider] = "\(reading.email ?? "That account") is already in agterm. Sign in with a different account."
            AccountStore.deleteHome(id, provider: provider)
            return
        }
        store.add(StoredAccount(id: id, provider: provider, label: reading.email ?? "\(provider.title) account",
                                email: reading.email, plan: reading.plan, enabled: true))
        message[provider] = "Added \(reading.email ?? "the account")."
        UsageMonitor.shared.refresh(provider, id)
    }
}
