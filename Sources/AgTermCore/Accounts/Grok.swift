import Foundation

/// A Grok login's auth.json: one entry per sign-in scope (`https://auth.x.ai::<client>`), each
/// with its access token (`key`), refresh token, account fields and `expires_at`. The CLI
/// refreshes the tokens itself and rewrites the file.
public enum GrokAuth {
    static let scopePrefix = "https://auth.x.ai::"
    static let legacyScope = "https://accounts.x.ai/sign-in"

    /// The sign-in a usage check uses. Never logged or shown.
    public struct Login: Equatable, Sendable {
        public let token: String
        public let email: String?
        public let expiresAt: Date?
    }

    /// The grok.com sign-in if there is one, else the legacy one, else any entry with a token.
    public static func login(_ json: [String: Any]) -> Login? {
        let entries = json.compactMap { scope, value -> (rank: Int, scope: String, entry: [String: Any])? in
            guard let entry = value as? [String: Any], (entry["key"] as? String)?.isEmpty == false else { return nil }
            let rank = scope.hasPrefix(scopePrefix) ? 0 : scope == legacyScope || scope.contains("/sign-in") ? 1 : 2
            return (rank, scope, entry)
        }
        guard let best = entries.min(by: { ($0.rank, $0.scope) < ($1.rank, $1.scope) }), let token = best.entry["key"] as? String else { return nil }
        return Login(token: token, email: (best.entry["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                     expiresAt: (best.entry["expires_at"] as? String).flatMap(date))
    }

    /// What agmux Teams takes: every entry a grok.com sign-in with a token, all for one user. A
    /// sign-in without a refresh token would stop working within hours, so that's refused too.
    public static func shareable(_ json: [String: Any]) -> Bool {
        guard !json.isEmpty else { return false }
        var users = Set<String>()
        for (scope, value) in json {
            guard scope.hasPrefix(scopePrefix) || scope == legacyScope, let entry = value as? [String: Any],
                  (entry["key"] as? String)?.isEmpty == false, (entry["refresh_token"] as? String)?.isEmpty == false else { return false }
            let user = entry["user_id"] as? String, principal = entry["principal_id"] as? String
            if let user, let principal, user != principal { return false }
            guard let id = user ?? principal, !id.isEmpty else { return false }
            users.insert(id)
        }
        return users.count == 1
    }

    /// `2026-10-26T20:32:45.335736Z`: ISO 8601 with up to nanoseconds, which the system parser
    /// doesn't take, so the fraction is dropped.
    static func date(_ text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}

/// grok.com's `GrokBuildBilling/GetGrokCreditsConfig` reply, which is what Grok's own usage view
/// shows. It is gRPC-web protobuf without a published schema; the CLI logs the same reply as
/// `creditUsagePercent` (field 1.1, a float), `currentPeriod.start` (1.4.1) and `.end` (1.5.1),
/// in Unix seconds. Read the way agmux and CodexBar read it, falling back to likely fields.
public enum GrokBilling {
    public struct Snapshot: Equatable, Sendable {
        public let usedPercent: Double
        public let resetsAt: Date?
        public let periodStart: Date?
    }

    public static let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    /// An empty gRPC-web request: no flags, zero length.
    public static let requestBody = Data([0, 0, 0, 0, 0])

    public static func parse(_ data: Data, now: Date) -> Snapshot? {
        let bytes = [UInt8](data)
        var payloads = frames(bytes) ?? []
        // Some replies are a bare message without framing.
        if payloads.isEmpty, let first = bytes.first, first >> 3 > 0, [0, 1, 2, 5].contains(first & 7) { payloads = [bytes[...]] }
        guard !payloads.isEmpty else { return nil }
        var scan = Scan()
        for payload in payloads { scan.read(payload, path: [], depth: 0) }

        let stamps = scan.varints.filter { (1_700_000_000...2_100_000_000).contains($0.value) }
        let nowSeconds = UInt64(max(0, now.timeIntervalSince1970))
        let future = stamps.filter { $0.value > nowSeconds }
        let reset = future.filter { $0.path == [1, 5, 1] }.map(\.value).min() ?? future.map(\.value).min()
        let start = stamps.filter { $0.path == [1, 4, 1] }.map(\.value).min()
            ?? stamps.filter { $0.value <= nowSeconds }.map(\.value).max()
        let hasPeriod = reset != nil
            && scan.varints.contains { $0.path.starts(with: [1, 6]) || ($0.path == [1, 8, 1] && [1, 2].contains($0.value)) }
        let percents = scan.floats.filter { $0.value.isFinite && (0...100).contains($0.value) }
        // creditUsagePercent is 1.1, and protobuf leaves a zero out, so in a known period a
        // missing one means nothing used yet. Otherwise take the likeliest float, as agmux does.
        let percent = percents.first { $0.path == [1, 1] }.map { Double($0.value) } ?? (hasPeriod ? 0
            : percents.filter { $0.path.last == 1 }.min { ($0.path.count, $0.order) < ($1.path.count, $1.order) }.map { Double($0.value) })
        guard let used = percent else { return nil }
        return Snapshot(usedPercent: used, resetsAt: reset.map { Date(timeIntervalSince1970: Double($0)) },
                        periodStart: start.map { Date(timeIntervalSince1970: Double($0)) })
    }

    /// The reading for a login: one window over the billing period.
    public static func reading(_ snapshot: Snapshot, plan: String?, email: String?, now: Date) -> UsageReading {
        let minutes: Int
        if let start = snapshot.periodStart, let end = snapshot.resetsAt, end > start {
            minutes = Int(end.timeIntervalSince(start) / 60)
        } else if let end = snapshot.resetsAt, end > now {
            // Snap to a week or a month when it's near one.
            let days = Int((end.timeIntervalSince(now) / 86_400).rounded())
            minutes = (4...12).contains(days) ? 10_080 : (20...45).contains(days) ? 43_200 : Int(end.timeIntervalSince(now) / 60)
        } else {
            minutes = 10_080
        }
        return UsageReading(windows: [UsageWindow(name: UsageParser.windowName(minutes: minutes), usedPercent: snapshot.usedPercent,
                                                  resetsAt: snapshot.resetsAt)],
                            plan: plan, email: email, checkedAt: now)
    }

    /// The plan ("SuperGrok Heavy"), from the newest `subscriptionTier` the CLI logged in
    /// logs/unified.jsonl; the billing reply doesn't name it.
    public static func plan(logTail: String) -> String? {
        for line in logTail.split(separator: "\n").reversed() where line.contains("\"subscriptionTier\"") {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let tier = (record["ctx"] as? [String: Any])?["subscriptionTier"] as? String else { continue }
            let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > 64 ? nil : trimmed
        }
        return nil
    }

    /// The data frames of a gRPC-web reply (flag bit 0x80 marks trailers), or nil if it isn't one.
    static func frames(_ bytes: [UInt8]) -> [ArraySlice<UInt8>]? {
        var frames: [ArraySlice<UInt8>] = []
        var index = 0
        while index < bytes.count {
            guard index + 5 <= bytes.count else { return nil }
            let length = bytes[index + 1 ... index + 4].reduce(0) { $0 << 8 | Int($1) }
            let start = index + 5, end = start + length
            guard end <= bytes.count else { return nil }
            if bytes[index] & 0x80 == 0 { frames.append(bytes[start..<end]) }
            index = end
        }
        return frames
    }

    /// Every varint and 32-bit float in a protobuf message, nested messages included, by field path.
    struct Scan {
        struct Field<Value> { let path: [UInt64]; let value: Value; let order: Int }
        var floats: [Field<Float>] = []
        var varints: [Field<UInt64>] = []
        private var order = 0

        mutating func read(_ buffer: ArraySlice<UInt8>, path: [UInt64], depth: Int) {
            guard depth <= 6 else { return }
            var i = buffer.startIndex
            while i < buffer.endIndex {
                guard let (key, next) = Self.varint(buffer, i) else { return }
                i = next
                let fieldPath = path + [key >> 3]
                switch key & 7 {
                case 0:
                    guard let (value, next) = Self.varint(buffer, i) else { return }
                    i = next
                    varints.append(Field(path: fieldPath, value: value, order: order))
                    order += 1
                case 1:
                    guard i + 8 <= buffer.endIndex else { return }
                    i += 8
                case 2:
                    guard let (length, next) = Self.varint(buffer, i), length <= UInt64(buffer.endIndex - next) else { return }
                    let end = next + Int(length)
                    read(buffer[next..<end], path: fieldPath, depth: depth + 1)
                    i = end
                case 5:
                    guard i + 4 <= buffer.endIndex else { return }
                    let bits = buffer[i..<i + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    floats.append(Field(path: fieldPath, value: Float(bitPattern: bits), order: order))
                    order += 1
                    i += 4
                default:
                    return
                }
            }
        }

        static func varint(_ buffer: ArraySlice<UInt8>, _ start: Int) -> (UInt64, Int)? {
            var result: UInt64 = 0, shift: UInt64 = 0, i = start
            while i < buffer.endIndex {
                let byte = buffer[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return (result, i) }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
    }
}

/// Grok keeps each conversation in `sessions/<folder, percent-encoded>/<session id>/`. A running
/// Grok doesn't hold those files open or record its pid anywhere, so agterm names each new
/// conversation itself (`--session-id`) to know which one a tab is in.
public enum GrokSessions {
    /// What to add to a Grok run's arguments (a session id of agterm's, for a new interactive
    /// conversation), and the conversation it will be in when that's known: the id agterm chose,
    /// or the one you resumed or picked. Nil for `--continue`, a bare `--resume` and forks.
    public static func launch(_ userArgs: [String], newID: () -> String) -> (extra: [String], sessionID: String?) {
        guard AgentKind.grok.startsSession(userArgs) else { return ([], nil) }
        func value(_ flags: Set<String>) -> String?? {
            for (i, arg) in userArgs.enumerated() {
                if let eq = arg.firstIndex(of: "="), flags.contains(String(arg[..<eq])) { return .some(String(arg[arg.index(after: eq)...])) }
                if flags.contains(arg) { return .some(i + 1 < userArgs.count && !userArgs[i + 1].hasPrefix("-") ? userArgs[i + 1] : nil) }
            }
            return .none
        }
        if userArgs.contains("--fork-session") { return ([], nil) }
        if case .some(let chosen) = value(["-s", "--session-id"]) { return ([], chosen) }
        if case .some(let resumed) = value(["-r", "--resume"]) { return ([], resumed) }
        let oneShot: Set<String> = ["-p", "--single", "--prompt-file", "--prompt-json", "-c", "--continue"]
        if userArgs.contains(where: { oneShot.contains($0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0) }) {
            return ([], nil)
        }
        let id = newID()
        return (["--session-id", id], id)
    }

    /// The one conversation Grok in `cwd` wrote to since `since`, for a run agterm didn't name
    /// (`--continue`). Nil when none did, or several did: then it can't tell which is this tab's.
    public static func written(in sessions: URL, cwd: String, since: Date) -> String? {
        let recent = conversations(in: sessions, cwd: cwd).filter { $0.modified >= since }
        return recent.count == 1 ? recent[0].id : nil
    }

    /// The conversation in `cwd` written to most recently, if that was since `since`: what a chat
    /// view follows when a new conversation (`/new`, `/clear`) replaces the one it showed.
    public static func latest(in sessions: URL, cwd: String, since: Date, excluding: Set<String> = []) -> String? {
        conversations(in: sessions, cwd: cwd).filter { $0.modified >= since && !excluding.contains($0.id) }
            .max { $0.modified < $1.modified }?.id
    }

    /// Which conversation a tab's Grok run shows: its own (`own`, the one agterm started or
    /// resumed), or a newer one in the same folder that this run started with `/new` or `/clear`.
    /// A newer one counts only when it was made after the run started, no other agterm tab runs it
    /// (`others`), and the tab was typed in just before it was made (`inputs`, when typing in the
    /// tab stopped) without its own conversation answering, so a conversation started outside agterm or in another tab isn't taken.
    /// `following` is the one shown now, kept while it is still the newest.
    public static func follow(in sessions: URL, cwd: String, own: String?, since: Date, others: Set<String>,
                              inputs: [Date], following: String? = nil) -> String? {
        let ownFile = own.flatMap { chatHistory(in: sessions, cwd: cwd, sessionID: $0) == nil ? nil : $0 }
        guard latest(in: sessions, cwd: cwd, since: since).map({ $0 != own }) == true,
              let newest = latest(in: sessions, cwd: cwd, since: since, excluding: others.subtracting([own].compactMap { $0 })),
              newest != own, chatHistory(in: sessions, cwd: cwd, sessionID: newest) != nil else { return ownFile }
        if own == nil || newest == following { return newest }
        // Typing its own conversation answered afterwards was a message to it, not `/new`.
        let answered = conversations(in: sessions, cwd: cwd).first { $0.id == own }?.modified
        let unanswered = inputs.filter { input in answered.map { $0 <= input.addingTimeInterval(answerSlack) } ?? true }
        guard let made = createdDate(in: sessions, cwd: cwd, sessionID: newest), made >= since.addingTimeInterval(-5),
              typed(before: made, inputs: unanswered) else { return ownFile }
        return newest
    }

    /// Grok may touch the old conversation's files as `/new` leaves it.
    static let answerSlack: TimeInterval = 2

    /// How long before a conversation is made the tab's typing (`/new`, then the prompt) may stop.
    static let typingWindow: TimeInterval = 60

    static func typed(before made: Date, inputs: [Date]) -> Bool {
        inputs.contains { $0 >= made.addingTimeInterval(-typingWindow) && $0 <= made.addingTimeInterval(5) }
    }

    /// When the conversation's folder was made.
    static func createdDate(in sessions: URL, cwd: String, sessionID: String) -> Date? {
        guard let dir = folder(in: sessions, cwd: cwd) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(sessionID).path))?[.creationDate] as? Date
    }

    /// The conversation `grok -c` reopens: the one in `cwd` written most recently.
    /// Nil for other runs, and for `--fork-session`, which starts a new one.
    public static func continued(_ userArgs: [String], in sessions: URL, cwd: String) -> String? {
        guard userArgs.contains(where: { $0 == "-c" || $0 == "--continue" }), !userArgs.contains("--fork-session") else { return nil }
        return latest(in: sessions, cwd: cwd, since: .distantPast)
    }

    /// A conversation's `chat_history.jsonl`, when it exists.
    public static func chatHistory(in sessions: URL, cwd: String, sessionID: String) -> URL? {
        guard let dir = folder(in: sessions, cwd: cwd) else { return nil }
        let file = dir.appendingPathComponent(sessionID).appendingPathComponent("chat_history.jsonl")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static func folder(in sessions: URL, cwd: String) -> URL? {
        let folder = ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [])
            .first { $0.removingPercentEncoding.map(standardized) == standardized(cwd) }
        return folder.map { sessions.appendingPathComponent($0, isDirectory: true) }
    }

    /// Each conversation in `cwd` and when it was last written.
    private static func conversations(in sessions: URL, cwd: String) -> [(id: String, modified: Date)] {
        guard let dir = folder(in: sessions, cwd: cwd) else { return [] }
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { id -> (id: String, modified: Date)? in
            guard id.range(of: #"^[0-9A-Za-z-]{8,64}$"#, options: .regularExpression) != nil else { return nil }
            let modified = ["chat_history.jsonl", "events.jsonl"].compactMap {
                (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(id).appendingPathComponent($0).path))?[.modificationDate] as? Date
            }.max()
            return modified.map { (id, $0) }
        }
    }

    /// The folder a Grok run works in: its `--cwd`, else where it was started.
    public static func folder(userArgs: [String], processCwd: String) -> String {
        for (i, arg) in userArgs.enumerated() {
            if arg.hasPrefix("--cwd=") { return String(arg.dropFirst("--cwd=".count)) }
            if arg == "--cwd", i + 1 < userArgs.count { return userArgs[i + 1] }
        }
        return processCwd
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
