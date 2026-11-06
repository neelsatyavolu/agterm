import AgTermCore
import CryptoKit
import Foundation

/// Uploads hourly usage totals for agent sessions started in agterm, like agmux's Teams sync:
/// every 2 minutes while signed in, over agmux's 90-day window, sending only hours that changed.
@MainActor
final class TeamsSync {
    static let shared = TeamsSync()

    private static let interval: TimeInterval = 120
    private nonisolated static let windowDays = 90.0
    private static let maxBucketsPerUpload = 2000
    private var timer: Timer?
    private var running = false
    private let worker = DispatchQueue(label: "agterm.teams", qos: .utility)
    /// Parsed events per transcript, reused while the file's modification date is unchanged.
    private var parsed: [String: (modified: Date, events: [UsageEvent])] = [:]
    /// Whether any of your teams shows Claude logins' emails, and when that was last asked.
    private var labelsWanted: (value: Bool, at: Date)?
    private static let labelsWantedFor: TimeInterval = 600

    func start() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncSoon()
    }

    func syncSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.sync() }
    }

    func sync() {
        let account = TeamsAccount.shared
        guard !running, account.isSignedIn, let token = account.token else { return }
        running = true
        let claims = TeamsClaims.shared.claudeSessions
        let spans = TeamsLoginSpans.shared.all
        let cache = parsed
        worker.async { [weak self] in
            let result = Self.collectBuckets(claudeSessions: claims, spans: spans, cache: cache)
            Task { @MainActor in
                guard let self else { return }
                self.parsed = result.cache
                let labels = await self.wantsLabels(token: token) ? AccountLabel.from(spans) : []
                await self.upload(result.buckets, accounts: result.accounts, labels: labels, token: token)
                self.running = false
            }
        }
    }

    // MARK: Collecting

    private nonisolated static func collectBuckets(claudeSessions: Set<String>, spans: [LoginSpan],
                                                   cache: [String: (modified: Date, events: [UsageEvent])])
        -> (buckets: [HourlyBucket], accounts: [AccountBucket], cache: [String: (modified: Date, events: [UsageEvent])]) {
        let cutoff = Date().addingTimeInterval(-windowDays * 86400)
        // Costs are set per event while reading, as agmux does.
        let prices = PriceList.current()
        var next: [String: (modified: Date, events: [UsageEvent])] = [:]
        var events: [UsageEvent] = []

        func use(_ url: URL, parse: (String) -> [UsageEvent]) {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= cutoff else { return }
            if let hit = cache[url.path], hit.modified == modified {
                next[url.path] = hit
                events += hit.events
                return
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let parsedEvents = parse(text)
            next[url.path] = (modified, parsedEvents)
            events += parsedEvents
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        // Claude: ~/.claude/projects/<encoded cwd>/<session id>.jsonl, only for sessions seen in agterm.
        let projects = home.appendingPathComponent(".claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for id in claudeSessions {
                let file = dir.appendingPathComponent(id + ".jsonl")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                use(file) { ClaudeTranscript.parse(lines: $0, sessionID: id, fallbackDir: dir.lastPathComponent, prices: prices) }
            }
        }
        // Codex: rollouts whose header says they were started in agterm.
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex")
        let sessions = codexHome.appendingPathComponent("sessions")
        if let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let header = firstLine(of: file), CodexTranscript.originator(header: header) == "agterm" else { continue }
                use(file) { CodexTranscript.parse(lines: $0, sessionID: file.deletingPathExtension().lastPathComponent, prices: prices) }
            }
        }
        let now = Date()
        let buckets = TeamsAggregator.buckets(events: events, now: now, timeZone: .current)
        let accounts = TeamsAggregator.accountBuckets(events: events, spans: LoginSpanIndex(spans), now: now)
        return (buckets, accounts, next)
    }

    private nonisolated static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// The exact upload body for these Claude sessions plus agterm's Codex sessions, without sending
    /// it (self-test and debugging).
    nonisolated static func previewPayload(claudeSessions: Set<String>) -> [String: Any] {
        let collected = collectBuckets(claudeSessions: claudeSessions, spans: TeamsLoginSpans.shared.all, cache: [:])
        return payload(buckets: collected.buckets, accounts: collected.accounts, labels: [])
    }

    /// One upload body: the service's `IncomingBucket`s plus the per-login split
    /// (docs/teams-usage-by-login.md in agmux). `accountsReported` tells the dashboard this app
    /// splits by login, so a member with nothing attributed isn't read as an old app.
    nonisolated static func payload(buckets: [HourlyBucket], accounts: [AccountBucket], labels: [AccountLabel]) -> [String: Any] {
        let encoder = JSONEncoder()
        func objects<T: Encodable>(_ values: [T]) -> [Any] { values.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) } }
        var body: [String: Any] = ["batchId": UUID().uuidString.lowercased(), "timezone": TimeZone.current.identifier,
                                   "buckets": objects(buckets), "accountBuckets": objects(accounts), "accountsReported": true]
        if !labels.isEmpty { body["accountLabels"] = objects(labels) }
        return body
    }

    // MARK: Uploading

    private static let stateURL = AgentIntegration.supportDir.appendingPathComponent("teams-sync-state.json")

    /// Uploads hours whose totals changed since the last accepted upload, with the per-login
    /// hours that changed and, when a team shows them, the Claude logins' emails.
    private func upload(_ buckets: [HourlyBucket], accounts: [AccountBucket], labels: [AccountLabel], token: String) async {
        var sent = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.stateURL))) ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // SHA-256 of the sorted JSON: stable across launches, unlike Swift's seeded hashValue.
        func digest<T: Encodable>(_ value: T) -> String? {
            (try? encoder.encode(value)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
        func changes<T: Encodable>(_ values: [T], key: (T) -> String) -> [(key: String, hash: String, value: T)] {
            values.compactMap { value in
                guard let hash = digest(value), sent[key(value)] != hash else { return nil }
                return (key(value), hash, value)
            }
        }
        let changed = changes(buckets) { [$0.hourUtc, $0.provider, $0.model, $0.projectKey].joined(separator: "|") }
        let changedAccounts = changes(accounts) { ["account", $0.hourUtc, $0.provider, $0.identityHash].joined(separator: "|") }
        let labelsHash = labels.isEmpty ? nil : digest(labels)
        let newLabels = labelsHash != nil && sent["account-labels"] != labelsHash
        guard !changed.isEmpty || !changedAccounts.isEmpty || newLabels else { return }
        let size = Self.maxBucketsPerUpload
        let chunks = max(1, (changed.count + size - 1) / size, (changedAccounts.count + size - 1) / size)
        do {
            for index in 0..<chunks {
                let part = Array(changed.dropFirst(index * size).prefix(size))
                let accountPart = Array(changedAccounts.dropFirst(index * size).prefix(size))
                let body = Self.payload(buckets: part.map(\.value), accounts: accountPart.map(\.value),
                                        labels: index == 0 && newLabels ? labels : [])
                let _: UploadReceipt = try await TeamsAccount.post("/api/metrics/upload", body: body, token: token)
                for item in part { sent[item.key] = item.hash }
                for item in accountPart { sent[item.key] = item.hash }
                if index == 0, newLabels { sent["account-labels"] = labelsHash }
            }
            try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(sent).write(to: Self.stateURL, options: .atomic)
            TeamsAccount.shared.lastUpload = Date()
        } catch TeamsAccount.TeamsError.unauthorized {
            TeamsAccount.shared.tokenRejected()
        } catch {
            NSLog("agterm: Teams upload failed: %@", error.localizedDescription)
        }
    }

    /// Whether any of your teams' owners turned on Shared Claude accounts, which is when Claude
    /// logins' emails go up with the usage. Asked at most every 10 minutes; unknown reads as no.
    private func wantsLabels(token: String) async -> Bool {
        if let cached = labelsWanted, Date().timeIntervalSince(cached.at) < Self.labelsWantedFor { return cached.value }
        var wanted = false
        do {
            let list: TeamList = try await TeamsAccount.send("GET", "/api/teams", token: token)
            for team in list.teams {
                let activity: Activity = try await TeamsAccount.send("GET", "/api/teams/\(team.id)/provider-accounts/activity", token: token)
                if activity.claudeActivity { wanted = true; break }
            }
        } catch {
            NSLog("agterm: couldn't read the teams' login settings: %@", error.localizedDescription)
            return labelsWanted?.value ?? false
        }
        labelsWanted = (wanted, Date())
        return wanted
    }

    private struct TeamList: Decodable { struct Team: Decodable { let id: String }; let teams: [Team] }
    private struct Activity: Decodable { let claudeActivity: Bool }
    private struct UploadReceipt: Decodable {}
}

/// OpenRouter's public model price list, cached for a day, which agmux also prices from.
enum PriceList {
    private static let url = URL(string: "https://openrouter.ai/api/v1/models")!
    private static let cacheURL = AgentIntegration.supportDir.appendingPathComponent("openrouter-models.json")

    /// The cached catalog (refreshed in the background when older than a day), or built-in prices.
    static func current() -> PriceCatalog {
        // Not URL.resourceValues: the static URL would keep its first date off the main thread,
        // and the list would be fetched on every sync once a day old.
        let modified = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if modified.map({ Date().timeIntervalSince($0) > 86400 }) ?? true { refresh() }
        if let data = try? Data(contentsOf: cacheURL), let catalog = try? PriceCatalog(openRouterJSON: data) { return catalog }
        return PriceCatalog.builtIn
    }

    private static func refresh() {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200, (try? PriceCatalog(openRouterJSON: data)) != nil else { return }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }.resume()
    }
}
