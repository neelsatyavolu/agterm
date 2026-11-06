import AgTermCore
import Foundation

/// Which login each Claude/Codex session started in agterm ran on, so agmux Teams can split a
/// member's usage by login. The wrapper writes the login into the tab's launch record; when a tab
/// learns its session id, the two are joined here into a span starting at the launch. Kept in
/// Application Support; only hashes, Claude emails and session ids, never transcript content.
final class TeamsLoginSpans {
    static let shared = TeamsLoginSpans()

    /// A session last started longer ago than this has nothing left in Teams' 90-day window.
    private static let keepFor: TimeInterval = 120 * 86400
    private let url = AgentIntegration.supportDir.appendingPathComponent("teams-login-spans.json")
    private let lock = NSLock()
    private var spans: [LoginSpan]

    private init() {
        spans = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([LoginSpan].self, from: $0) } ?? []
    }

    var all: [LoginSpan] {
        lock.lock(); defer { lock.unlock() }
        return spans
    }

    /// Records that `sessionID` runs on the login `launch` names, from the launch on. A launch
    /// whose login files named none leaves the session unattributed.
    func record(_ provider: AccountProvider, sessionID: String, launch: TabLaunch) {
        guard let hash = launch.identityHash, provider == .claude || provider == .codex else { return }
        let fromMs = Int64((launch.startedAt.timeIntervalSince1970 * 1000).rounded(.down))
        let span = LoginSpan(provider: provider.rawValue, sessionID: sessionID, identityHash: hash,
                             label: provider == .claude ? launch.loginLabel : nil, fromMs: fromMs)
        lock.lock()
        guard !spans.contains(where: { $0.provider == span.provider && $0.sessionID == sessionID && $0.fromMs == fromMs }) else {
            lock.unlock()
            return
        }
        spans.append(span)
        spans = Self.pruned(spans, now: Date())
        let snapshot = spans
        lock.unlock()
        save(snapshot)
    }

    /// Drops sessions whose newest span is past the window; older spans of a live session stay,
    /// since its earlier hours still need them.
    private static func pruned(_ spans: [LoginSpan], now: Date) -> [LoginSpan] {
        let cutoff = Int64((now.timeIntervalSince1970 - keepFor) * 1000)
        var newest: [String: Int64] = [:]
        for s in spans { newest[s.provider + "|" + s.sessionID] = max(newest[s.provider + "|" + s.sessionID] ?? .min, s.fromMs) }
        return spans.filter { (newest[$0.provider + "|" + $0.sessionID] ?? .min) >= cutoff }
    }

    private func save(_ spans: [LoginSpan]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(spans).write(to: url, options: .atomic)
        } catch {
            NSLog("agterm: couldn't save Teams login records: %@", error.localizedDescription)
        }
    }
}
