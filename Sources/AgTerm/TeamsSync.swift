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
        let cache = parsed
        worker.async { [weak self] in
            let result = Self.collectBuckets(claudeSessions: claims, cache: cache)
            Task { @MainActor in
                guard let self else { return }
                self.parsed = result.cache
                await self.upload(result.buckets, token: token)
                self.running = false
            }
        }
    }

    // MARK: Collecting

    private nonisolated static func collectBuckets(claudeSessions: Set<String>,
                                                   cache: [String: (modified: Date, events: [UsageEvent])])
        -> (buckets: [HourlyBucket], cache: [String: (modified: Date, events: [UsageEvent])]) {
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
        let buckets = TeamsAggregator.buckets(events: events, now: Date(), timeZone: .current)
        return (buckets, next)
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
        let buckets = collectBuckets(claudeSessions: claudeSessions, cache: [:]).buckets
        let encoder = JSONEncoder()
        return ["batchId": UUID().uuidString.lowercased(), "timezone": TimeZone.current.identifier,
                "buckets": buckets.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) }]
    }

    // MARK: Uploading

    private static let stateURL = AgentIntegration.supportDir.appendingPathComponent("teams-sync-state.json")

    /// Uploads hours whose totals changed since the last accepted upload.
    private func upload(_ buckets: [HourlyBucket], token: String) async {
        var sent = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.stateURL))) ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var changed: [(key: String, hash: String, bucket: HourlyBucket)] = []
        for bucket in buckets {
            guard let data = try? encoder.encode(bucket) else { continue }
            let key = [bucket.hourUtc, bucket.provider, bucket.model, bucket.projectKey].joined(separator: "|")
            // SHA-256 of the sorted JSON: stable across launches, unlike Swift's seeded hashValue.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if sent[key] != digest { changed.append((key, digest, bucket)) }
        }
        guard !changed.isEmpty else { return }
        do {
            for chunk in stride(from: 0, to: changed.count, by: Self.maxBucketsPerUpload) {
                let part = Array(changed[chunk..<min(chunk + Self.maxBucketsPerUpload, changed.count)])
                let body: [String: Any] = [
                    "batchId": UUID().uuidString.lowercased(),
                    "timezone": TimeZone.current.identifier,
                    "buckets": try part.map { try JSONSerialization.jsonObject(with: encoder.encode($0.bucket)) },
                ]
                let _: UploadReceipt = try await TeamsAccount.post("/api/metrics/upload", body: body, token: token)
                for item in part { sent[item.key] = item.hash }
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
