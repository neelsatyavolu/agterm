import Foundation

/// A transcript parser fed one JSONL line at a time, so a file that keeps growing can be read
/// a chunk at a time instead of from the start on every poll.
public protocol TranscriptLineParser {
    /// One line, without its newline.
    mutating func feed(_ line: String)
    /// The usage events so far, as a whole-file parse of the lines fed would return them.
    var events: [UsageEvent] { get }
}

extension TranscriptLineParser {
    /// Feeds every complete line in `chunk` and returns how many bytes that used: up to and
    /// including the last newline. A trailing partial line is left for the next chunk.
    public mutating func feed(chunk: Data) -> Int {
        guard let end = chunk.lastIndex(of: 0x0A) else { return 0 }
        let complete = chunk[chunk.startIndex...end]
        for piece in complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let trimmed = piece.last == 0x0D ? piece.dropLast() : piece
            feed(String(decoding: trimmed, as: UTF8.self))
        }
        return complete.count
    }
}

extension CodexTranscript {
    /// `parse`, a line at a time.
    public struct Parser: TranscriptLineParser {
        private var rollout: CodexRolloutParser

        public init(sessionID: String, prices: PriceCatalog = .builtIn) {
            rollout = CodexRolloutParser(sessionID: sessionID, prices: prices)
        }

        public mutating func feed(_ line: String) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let v = JSONValue.parse(line) else { return }
            rollout.consume(v)
        }

        public var events: [UsageEvent] {
            var copy = rollout
            return copy.finish().events
        }
    }
}
