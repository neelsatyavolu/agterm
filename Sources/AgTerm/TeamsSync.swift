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
    /// What the last sync read, so the next one reads only what agents added since.
    private var memory = Memory()
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
        let memory = memory
        worker.async { [weak self] in
            let result = Self.collectBuckets(claudeSessions: claims, spans: spans, memory: memory)
            Task { @MainActor in
                guard let self else { return }
                self.memory = result.memory
                let labels = await self.wantsLabels(token: token) ? AccountLabel.from(spans) : []
                await self.upload(result.buckets, accounts: result.accounts, labels: labels, token: token)
                self.running = false
            }
        }
    }

    // MARK: Collecting

    /// What a sync keeps for the next one: each transcript's read position, parser state and
    /// events; where each Claude session's transcript is; which Codex rollouts agterm started.
    struct Memory {
        struct Tail {
            var offset: UInt64
            var parser: any TranscriptLineParser
            var events: [UsageEvent]
        }
        var tails: [String: Tail] = [:]
        var claudeFiles: [String: [URL]] = [:]
        var codexStarted: [String: Bool] = [:]
    }

    private nonisolated static func collectBuckets(claudeSessions: Set<String>, spans: [LoginSpan], memory: Memory)
        -> (buckets: [HourlyBucket], accounts: [AccountBucket], memory: Memory) {
        let cutoff = Date().addingTimeInterval(-windowDays * 86400)
        // Costs are set per event when a line is first read, as agmux does.
        let prices = PriceList.current()
        var next = Memory(claudeFiles: memory.claudeFiles, codexStarted: memory.codexStarted)
        var events: [UsageEvent] = []

        // Agents only append, so only the lines added since the last sync are read.
        func use(_ file: URL, parser makeParser: () -> any TranscriptLineParser) {
            // Per file, so URLs and strings made while reading are freed as it goes.
            autoreleasepool {
                // Not URL.resourceValues: it caches on the URL.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let modified = attributes[.modificationDate] as? Date, modified >= cutoff,
                      let size = attributes[.size] as? UInt64 else { return }
                var tail = memory.tails[file.path]
                // A shorter file was replaced or rewritten: start over.
                if tail == nil || size < tail!.offset { tail = Memory.Tail(offset: 0, parser: makeParser(), events: []) }
                guard var tail else { return }
                if size > tail.offset {
                    guard let end = TranscriptFile.read(file.path, from: tail.offset, line: { tail.parser.feed($0) }) else { return }
                    tail.offset = end
                    tail.events = tail.parser.events
                }
                next.tails[file.path] = tail
                events += tail.events
            }
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        // Claude: ~/.claude/projects/<encoded cwd>/<session id>.jsonl, only for sessions seen in agterm.
        let unfound = claudeSessions.filter { next.claudeFiles[$0] == nil }
        if !unfound.isEmpty {
            let projects = home.appendingPathComponent(".claude/projects")
            for dir in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                for id in unfound {
                    let file = dir.appendingPathComponent(id + ".jsonl")
                    if FileManager.default.fileExists(atPath: file.path) { next.claudeFiles[id, default: []].append(file) }
                }
            }
        }
        for id in claudeSessions {
            for file in next.claudeFiles[id] ?? [] {
                let dir = file.deletingLastPathComponent().lastPathComponent
                use(file) { ClaudeTranscript.Parser(sessionID: id, fallbackDir: dir, prices: prices) }
                // Its subagents and workflow agents: their usage is the session's, not new sessions.
                for child in ClaudeTranscript.subagentFiles(of: file) {
                    use(child) { ClaudeTranscript.Parser(sessionID: id, fallbackDir: dir + "/" + id + "/subagents", prices: prices) }
                }
            }
        }
        // Codex: rollouts whose header says they were started in agterm. A header never changes.
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex")
        let sessions = codexHome.appendingPathComponent("sessions")
        if let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                let started = next.codexStarted[file.path] ?? autoreleasepool {
                    firstLine(of: file).map { CodexTranscript.originator(header: $0) == "agterm" }
                }
                // A header still being written (or unreadable) is asked again next time.
                if let started { next.codexStarted[file.path] = started }
                guard started == true else { continue }
                use(file) { CodexTranscript.Parser(sessionID: file.deletingPathExtension().lastPathComponent, prices: prices) }
            }
        }
        // A request copied into both a session's transcript and a subagent's counts once.
        events = ClaudeTranscript.reconcile(events)
        let now = Date()
        let buckets = TeamsAggregator.buckets(events: events, now: now, timeZone: .current)
        let accounts = TeamsAggregator.accountBuckets(events: events, spans: LoginSpanIndex(spans), now: now)
        return (buckets, accounts, next)
    }

    /// The first line, once it's complete (ends in a newline within the first 256 KB).
    private nonisolated static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024), let end = data.firstIndex(of: 0x0A) else { return nil }
        return String(decoding: data[..<end], as: UTF8.self)
    }

    /// The exact upload body for these Claude sessions plus agterm's Codex sessions, without sending
    /// it (self-test and debugging).
    nonisolated static func previewPayload(claudeSessions: Set<String>) -> [String: Any] {
        let collected = collectBuckets(claudeSessions: claudeSessions, spans: TeamsLoginSpans.shared.all, memory: Memory())
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
        // The server deletes Claude emails when an owner turns sharing off, so forget what was
        // sent; turning it back on then sends them again.
        if labels.isEmpty, sent.removeValue(forKey: "account-labels") != nil {
            try? JSONEncoder().encode(sent).write(to: Self.stateURL, options: .atomic)
        }
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

/// Model prices: agterm's own list (`prices.json` in the repo, so a new model is priced without an
/// app update) over the built-in table, then OpenRouter's public list. Both lists are cached for a day.
enum PriceList {
    private static let sources: [(url: URL, cache: URL, valid: @Sendable (Data) -> Bool)] = [
        (URL(string: "https://openrouter.ai/api/v1/models")!, AgentIntegration.supportDir.appendingPathComponent("openrouter-models.json"),
         { (try? PriceCatalog(openRouterJSON: $0)) != nil }),
        (RemotePrices.url, AgentIntegration.supportDir.appendingPathComponent("prices.json"),
         { (try? PriceCatalog.builtIn.adding(priceList: $0)) != nil }),
    ]

    private static let lock = NSLock()
    /// The last catalog built, the files' dates it was built from, and when.
    nonisolated(unsafe) private static var built: (catalog: PriceCatalog, dates: [Date?], at: Date)?
    /// When each list was last asked for, so being offline doesn't ask on every call.
    nonisolated(unsafe) private static var asked: [URL: Date] = [:]

    /// The cached lists (each refreshed in the background when older than a day) over the
    /// built-in prices. Built again only when a list changes, or hourly.
    static func current() -> PriceCatalog {
        // Not URL.resourceValues: the static URL would keep its first date off the main thread,
        // and the list would be fetched on every sync once a day old.
        let dates = sources.map { (try? FileManager.default.attributesOfItem(atPath: $0.cache.path))?[.modificationDate] as? Date }
        for (source, date) in zip(sources, dates) where date.map({ Date().timeIntervalSince($0) > 86400 }) ?? true {
            refresh(source.url, to: source.cache, valid: source.valid)
        }
        lock.lock()
        defer { lock.unlock() }
        if let built, built.dates == dates, Date().timeIntervalSince(built.at) < 3600 { return built.catalog }
        var catalog = (try? Data(contentsOf: sources[0].cache)).flatMap { try? PriceCatalog(openRouterJSON: $0) } ?? .builtIn
        if let data = try? Data(contentsOf: sources[1].cache), let withList = try? catalog.adding(priceList: data) { catalog = withList }
        built = (catalog, dates, Date())
        return catalog
    }

    private static func refresh(_ url: URL, to cache: URL, valid: @escaping @Sendable (Data) -> Bool) {
        lock.lock()
        let recent = asked[url].map { Date().timeIntervalSince($0) < 600 } ?? false
        if !recent { asked[url] = Date() }
        lock.unlock()
        guard !recent else { return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200, valid(data) else { return }
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }.resume()
    }
}
