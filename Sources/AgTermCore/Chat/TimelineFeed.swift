import Foundation

/// An agent's transcript read as it grows: feed it the bytes appended since the last read and
/// it keeps the whole timeline. Agents only append, so the caller reads from `offset` on each
/// poll; a file that got shorter or was replaced needs a new feed.
public struct TimelineFeed {
    public enum Agent: String, Sendable {
        case claude, codex, grok, agl
    }

    public let agent: Agent
    /// Every row so far (not capped like the phone's), oldest first.
    public private(set) var entries: [MobileTimelineEntry] = []
    /// The raw model id of the latest reply, when the transcript names one.
    public private(set) var model: String?
    /// Bytes used so far: through the last complete line.
    public private(set) var offset = 0

    private var claude = ClaudeTimeline.Fold(chatMarkers: true)
    /// Claude queue records, with where each line starts, for the queue overlay.
    private var claudeQueue: [(start: Int, line: String)] = []
    /// Codex rows can depend on later records (a command's output, a tool's result). The parser
    /// and converter hold everything up to the last point where nothing was waiting; only the
    /// records after it are parsed again on each read.
    private var codexParser = CodexHistoryParser(chatMarkers: true)
    private var codexConverter = CodexTimeline.Converter()
    private var codexTail: [JSONValue] = []
    private var grok = GrokTimeline()
    private var agl = AglTimeline()

    /// Strings longer than this in kept Codex records are cut; rows show far less.
    static let codexStringLimit = 256 * 1024

    /// `offset`: where in the file reading starts (the start of a line), for a feed that skips
    /// the oldest part of a very long transcript.
    public init(agent: Agent, offset: Int = 0) {
        self.agent = agent
        self.offset = offset
        startOffset = offset
    }

    /// Where this feed started reading; above 0 when older history was left out.
    public let startOffset: Int

    /// Feeds every complete line in `chunk` (the file's bytes from `offset` on) and returns how
    /// many bytes that used. A trailing partial line, still being written, is left for next time.
    @discardableResult
    public mutating func feed(chunk: Data) -> Int {
        var lineStart = offset
        let used = forEachCompleteLine(in: chunk) { line in
            consume(line, start: lineStart)
            lineStart += line.utf8.count + 1
        }
        guard used > 0 else { return 0 }
        offset += used
        rebuild()
        return used
    }

    private mutating func consume(_ line: String, start: Int) {
        switch agent {
        case .claude:
            let trimmed = line.rustTrimmed
            guard !trimmed.isEmpty else { return }
            if trimmed.containsBytes("queue-operation") || trimmed.containsBytes("queued_command") {
                claudeQueue.append((start, trimmed))
            }
            guard ClaudeTimeline.mayHaveRows(trimmed), let record = JSONValue.parse(trimmed) else { return }
            ClaudeTimeline.parseRecord(record).forEach { claude.add($0) }
            if let model = ClaudeTimeline.assistantModel(record) { self.model = model }
        case .codex:
            let trimmed = line.rustTrimmed
            guard !trimmed.isEmpty, let record = JSONValue.parse(trimmed) else { return }
            if record["type"]?.string == "turn_context", let model = record.pointer("/payload/model")?.string, !model.isEmpty {
                self.model = model
            }
            // No string in it can be longer than the line itself.
            codexTail.append(trimmed.utf8.count > Self.codexStringLimit ? record.cappingStrings(at: Self.codexStringLimit) : record)
        case .grok:
            grok.feed(line)
            model = grok.model
        case .agl:
            agl.feed(line)
            model = agl.model
        }
    }

    private mutating func rebuild() {
        switch agent {
        case .claude:
            // As `ClaudeTimeline.applyingQueueOverlay`: only queue records in the transcript's last 256 KB count.
            let tailStart = offset - ClaudeTimeline.queueTailBytes
            let lines = claudeQueue.filter { $0.start > tailStart }.map(\.line)
            let (delivered, pending) = ClaudeTimeline.scanQueue(lines)
            entries = delivered.isEmpty && pending.isEmpty
                ? claude.entries
                : ClaudeTimeline.mergeQueue(claude.entries, delivered: delivered, pending: pending)
        case .codex:
            var parser = codexParser
            codexTail.forEach { parser.consume($0) }
            if parser.isSettled {
                parser.takeSettledItems().forEach { codexConverter.add($0) }
                codexConverter.forgetCalls()
                codexParser = parser
                codexTail = []
                entries = codexConverter.entries
            } else {
                var converter = codexConverter
                parser.finishedItems().forEach { converter.add($0) }
                entries = converter.entries
            }
        case .grok:
            entries = grok.entries
        case .agl:
            entries = agl.entries
        }
    }
}

/// Where two versions of a list first differ, so a view replaces only the changed tail.
public enum TimelineDiff {
    /// The first index whose element differs (in id or content), or where one list ends before
    /// the other; nil when they're equal.
    public static func firstChange<T: Equatable>(from old: [T], to new: [T]) -> Int? {
        let shared = min(old.count, new.count)
        if let index = (0..<shared).first(where: { old[$0] != new[$0] }) { return index }
        return old.count == new.count ? nil : shared
    }
}

extension JSONValue {
    /// The same value with every string longer than `limit` UTF-8 bytes cut to about that.
    func cappingStrings(at limit: Int) -> JSONValue {
        switch self {
        case .string(let text) where text.utf8.count > limit:
            return .string(String(decoding: text.utf8.prefix(limit), as: UTF8.self))
        case .array(let items):
            return .array(items.map { $0.cappingStrings(at: limit) })
        case .object(let fields):
            return .object(fields.mapValues { $0.cappingStrings(at: limit) })
        default:
            return self
        }
    }
}
