import Foundation

/// Reads what an agent appended to its transcript since the last read, a few MB at a time, so a
/// long transcript is never held in memory whole and a growing one is never read from the start.
public enum TranscriptFile {
    /// Calls `line` with each complete line from `offset` on (without its newline or a trailing
    /// `\r`) and returns the offset just past the last one. A trailing partial line is left for
    /// the next read. Nil when the file can't be opened or read.
    public static func read(_ path: String, from offset: UInt64, chunkSize: Int = 4 << 20,
                            line: (String) -> Void) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return nil }
        var position = offset
        var pending = Data()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: chunkSize) } catch { return nil }
            // Nil or empty: the end of the file.
            guard let more = chunk, !more.isEmpty else { return position }
            pending.append(more)
            guard let end = pending.lastIndex(of: 0x0A) else { continue }
            for piece in pending[pending.startIndex..<end].split(separator: 0x0A, omittingEmptySubsequences: false) {
                line(String(decoding: piece.last == 0x0D ? piece.dropLast() : piece, as: UTF8.self))
            }
            let next = pending.index(after: end)
            position += UInt64(pending.distance(from: pending.startIndex, to: next))
            pending = Data(pending[next...])
        }
    }
}
