import Foundation

/// Folds per-event provider activity into the hourly buckets the Teams service
/// accepts. Pure arithmetic: no files, network or clock reads.
///
/// The fiddly parts are spans that straddle an hour boundary, concurrency being a
/// max rather than a sum, and idle time not counting as active time.
public enum TeamsAggregator {
    /// Longest gap between two events in a session that still counts as the agent
    /// working. Anything longer is the person thinking, at lunch, or gone.
    public static let activeGapCap: TimeInterval = 5 * 60
    /// Credited to a session's last event, which has nothing after it to measure against.
    public static let activeTail: TimeInterval = 30
    /// Work outside 08:00–18:00 on the member's own wall clock is after hours.
    static let workHours = 8..<18

    private static let gapCapMicros = Int64(activeGapCap * 1_000_000)
    private static let tailMicros = Int64(activeTail * 1_000_000)
    private static let hourMicros: Int64 = 3_600_000_000

    /// Reduces a working directory to an uploadable label: the basename for a
    /// public repo, an 8-character hash for a private one. Never a path.
    public static func projectKey(workDir: String, private isPrivate: Bool) -> String {
        TeamsLabels.projectKey(workDir: workDir, private: isPrivate)
    }

    /// The member's IANA zone by name, falling back to UTC for unknown names.
    public static func timeZone(named name: String) -> TimeZone {
        TimeZone(identifier: name) ?? utc
    }

    /// Builds hourly buckets. Events after `now` (clock skew) are ignored. After
    /// hours, weekend and the local hour/weekday are judged in `timeZone`.
    public static func buckets(events: [UsageEvent], now: Date, timeZone: TimeZone) -> [HourlyBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var acc: [BucketKey: HourlyBucket] = [:]
        var sessionHours: [SessionHour: BucketKey] = [:]
        var timelines: [SessionID: [(at: Int64, ident: Ident)]] = [:]
        var sessionStarts: [SessionID: (at: Int64, key: BucketKey)] = [:]
        let nowMicros = TeamsTime.micros(now)

        for e in events {
            let at = TeamsTime.micros(e.at)
            if at > nowMicros { continue }
            let key = BucketKey(hour: TeamsTime.hourKey(e.at), ident: Ident(
                provider: e.provider,
                model: TeamsLabels.wireLabel(e.model, maxUnits: 60),
                project: TeamsLabels.wireLabel(e.projectKey, maxUnits: 64)))
            acc[key] = adding(e, to: acc[key] ?? newBucket(e.at, key, calendar))

            keepMin(&sessionHours, SessionHour(hour: key.hour, provider: e.provider, session: e.sessionID), key)
            let session = SessionID(provider: e.provider, session: e.sessionID)
            if !e.subagent, !e.isSubagentPath {
                if let first = sessionStarts[session], !(at < first.at || (at == first.at && key < first.key)) {
                    // The earlier event already started this session.
                } else {
                    sessionStarts[session] = (at, key)
                }
            }
            timelines[session, default: []].append((at, key.ident))
        }

        // Active time and concurrency come from each session's continuous timeline,
        // so a gap from 13:58 to 14:01 is measured across the hour boundary.
        var spansByHour: [String: [Span]] = [:]
        for (session, timeline) in timelines {
            for (span, ident) in sessionSpans(timeline) {
                for (bucketStart, slice) in splitByHour(span) {
                    let bucketDate = TeamsTime.date(micros: bucketStart)
                    let key = BucketKey(hour: TeamsTime.hourKey(bucketDate), ident: ident)
                    keepMin(&sessionHours, SessionHour(hour: key.hour, provider: session.provider, session: session.session), key)
                    var b = acc[key] ?? newBucket(bucketDate, key, calendar)
                    let ms = Int((slice.end - slice.start) / 1000)
                    b.activeMs += ms
                    // Judged on the slice in the member's zone, so a session crossing
                    // 18:00 local splits honestly.
                    let local = calendar.dateComponents([.hour, .weekday], from: TeamsTime.date(micros: slice.start))
                    if !workHours.contains(local.hour ?? 0) { b.afterHoursMs += ms }
                    if mondayBased(local.weekday) >= 5 { b.weekendMs += ms }
                    acc[key] = b
                    spansByHour[key.hour, default: []].append(slice)
                }
            }
        }

        let peaks = spansByHour.mapValues(peakOverlap)
        for key in acc.keys { acc[key]?.peakConcurrent = peaks[key.hour] ?? 0 }
        for key in sessionHours.values { acc[key]?.sessions += 1 }
        for (_, key) in sessionStarts.values {
            let started = acc[key]?.sessionsStarted ?? 0
            acc[key]?.sessionsStarted = started + 1
        }

        return acc.sorted { $0.key < $1.key }.map(\.value)
    }

    // MARK: - Folding

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    private static func newBucket(_ at: Date, _ key: BucketKey, _ calendar: Calendar) -> HourlyBucket {
        var b = HourlyBucket()
        (b.hourUtc, b.provider, b.model, b.projectKey) = (key.hour, key.ident.provider, key.ident.model, key.ident.project)
        let local = calendar.dateComponents([.hour, .weekday], from: at)
        b.localHour = local.hour ?? 0
        b.localDow = mondayBased(local.weekday)
        b.sessionsStarted = 0
        return b
    }

    private static func adding(_ e: UsageEvent, to bucket: HourlyBucket) -> HourlyBucket {
        var b = bucket
        b.tokensIn += e.tokensIn
        b.tokensOut += e.tokensOut
        b.tokensCacheRead += e.cacheRead
        b.tokensCacheWrite += e.cacheWrite
        b.tokensReasoning += e.reasoning
        b.costUsd += e.costUSD
        b.costIncomplete = b.costIncomplete || e.costIncomplete
        b.toolCalls += e.toolCalls
        let t = e.tools
        (b.toolBash, b.toolEdit, b.toolRead, b.toolSearch) =
            (b.toolBash + t.bash, b.toolEdit + t.edit, b.toolRead + t.read, b.toolSearch + t.search)
        (b.toolWeb, b.toolAgent, b.toolMcp, b.toolOther) =
            (b.toolWeb + t.web, b.toolAgent + t.agent, b.toolMcp + t.mcp, b.toolOther + t.other)
        (b.toolErrors, b.toolsMeasured) = (b.toolErrors + t.errors, b.toolsMeasured + t.measured)
        (b.filesChanged, b.linesAdded, b.linesRemoved) =
            (b.filesChanged + t.filesChanged, b.linesAdded + t.linesAdded, b.linesRemoved + t.linesRemoved)
        if e.isTurn { b.turns += 1 }
        return b
    }

    /// Monday = 0 … Sunday = 6, from Calendar's Sunday = 1 weekday.
    private static func mondayBased(_ weekday: Int?) -> Int {
        ((weekday ?? 2) + 5) % 7
    }

    private static func keepMin(_ map: inout [SessionHour: BucketKey], _ id: SessionHour, _ key: BucketKey) {
        if let existing = map[id], !(key < existing) { return }
        map[id] = key
    }

    // MARK: - Spans

    /// Active spans for one session, each tagged with the identity running when it
    /// started. Each gap is capped; the last event gets a short tail.
    static func sessionSpans(_ timeline: [(at: Int64, ident: Ident)]) -> [(Span, Ident)] {
        // Stable sort by time, as Rust's sort_by.
        let ordered = timeline.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        guard let last = ordered.last else { return [] }
        var spans: [(Span, Ident)] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let end = b.at - a.at > gapCapMicros ? a.at + gapCapMicros : b.at
            if end > a.at { spans.append((Span(start: a.at, end: end), a.ident)) }
        }
        spans.append((Span(start: last.at, end: last.at + tailMicros), last.ident))
        return spans
    }

    /// Splits a span on UTC hour boundaries, returning each slice with its hour's start.
    static func splitByHour(_ span: Span) -> [(Int64, Span)] {
        var out: [(Int64, Span)] = []
        var cursor = span.start
        while cursor < span.end {
            let bucket = cursor - ((cursor % hourMicros) + hourMicros) % hourMicros
            let sliceEnd = min(bucket + hourMicros, span.end)
            out.append((bucket, Span(start: cursor, end: sliceEnd)))
            cursor = sliceEnd
        }
        return out
    }

    /// Maximum number of simultaneously open spans. Ends sort before starts at the
    /// same instant, so back-to-back spans do not read as overlapping.
    static func peakOverlap(_ spans: [Span]) -> Int {
        let edges = spans.flatMap { [($0.start, 1), ($0.end, -1)] }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var current = 0
        var peak = 0
        for (_, delta) in edges {
            current += delta
            peak = max(peak, current)
        }
        return peak
    }
}

/// A half-open `[start, end)` interval in microseconds since 1970.
struct Span: Equatable {
    var start: Int64
    var end: Int64
}

/// `(provider, model, project)`: what a span's time is attributed to.
struct Ident: Hashable {
    var provider: String
    var model: String
    var project: String
}

/// The server's bucket key minus identity, ordered byte-wise like Rust's tuples.
struct BucketKey: Hashable, Comparable {
    var hour: String
    var ident: Ident

    static func < (a: BucketKey, b: BucketKey) -> Bool {
        for (x, y) in [(a.hour, b.hour), (a.ident.provider, b.ident.provider), (a.ident.model, b.ident.model),
                       (a.ident.project, b.ident.project)] where x != y {
            return byteLess(x, y)
        }
        return false
    }
}

private struct SessionID: Hashable {
    var provider: String
    var session: String
}

private struct SessionHour: Hashable {
    var hour: String
    var provider: String
    var session: String
}
