import Foundation

/// Command-palette matching: the query's letters must appear in order (case, accents and the
/// query's spaces ignored). Letters that start words, runs of letters and matches near the
/// start score higher, so "sr" finds Split Right and "close" puts Close Tab first.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Offsets of the matched characters in the text, in `Character`s.
        public let positions: [Int]
    }

    public struct Ranked<Item> {
        public let item: Item
        public let match: Match
    }

    static let letterScore = 16
    static let wordStartBonus = 20
    static let firstLetterBonus = 8
    /// As much as a word start, so "spl" prefers Split over S(elect) P(ane) L(eft).
    static let runBonus = 20
    /// Per character skipped before the first match or between two matches.
    static let gapPenalty = 1

    /// The best way the query's letters appear in `text`, or nil if they don't all appear in order.
    public static func match(_ query: String, in text: String) -> Match? {
        let needle = query.filter { !$0.isWhitespace }.map(fold)
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }
        let original = Array(text)
        let hay = original.map(fold)
        let m = needle.count, n = hay.count
        guard m <= n else { return nil }
        let none = Int.min / 2
        // best[i][j]: the highest score with needle[i] matched at hay[j]; from[i][j] where needle[i-1] was.
        var best = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for j in 0..<n where hay[j] == needle[0] {
            best[0][j] = letterScore(at: j, in: original) - gapPenalty * j
        }
        for i in 1..<m {
            // The best earlier match at least two characters back, already charged for the gap to j.
            var carry = none, carryFrom = -1
            for j in i..<n {
                if j >= 2, best[i - 1][j - 2] > none {
                    let candidate = best[i - 1][j - 2] - gapPenalty
                    if candidate > carry { carry = candidate; carryFrom = j - 2 }
                }
                defer { if carry > none { carry -= gapPenalty } }
                guard hay[j] == needle[i] else { continue }
                var previous = carry, previousAt = carryFrom
                if best[i - 1][j - 1] > none, best[i - 1][j - 1] + runBonus >= previous {
                    previous = best[i - 1][j - 1] + runBonus
                    previousAt = j - 1
                }
                guard previous > none else { continue }
                best[i][j] = previous + letterScore(at: j, in: original)
                from[i][j] = previousAt
            }
        }
        guard let end = (0..<n).filter({ best[m - 1][$0] > none }).max(by: { best[m - 1][$0] < best[m - 1][$1] }) else {
            return nil
        }
        var positions = [end]
        for i in stride(from: m - 1, to: 0, by: -1) { positions.append(from[i][positions.last!]) }
        return Match(score: best[m - 1][end], positions: positions.reversed())
    }

    /// The items whose text matches, best first; equal scores keep the items' order.
    public static func rank<Item>(_ query: String, _ items: [Item], text: (Item) -> String) -> [Ranked<Item>] {
        items.enumerated()
            .compactMap { offset, item in match(query, in: text(item)).map { (offset, Ranked(item: item, match: $0)) } }
            .sorted { $0.1.match.score != $1.1.match.score ? $0.1.match.score > $1.1.match.score : $0.0 < $1.0 }
            .map(\.1)
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func letterScore(at j: Int, in text: [Character]) -> Int {
        var score = letterScore
        if j == 0 { score += firstLetterBonus }
        if isWordStart(j, in: text) { score += wordStartBonus }
        return score
    }

    /// The first character, one after a space or punctuation, or a capital after a lowercase letter.
    private static func isWordStart(_ j: Int, in text: [Character]) -> Bool {
        guard j > 0 else { return true }
        let previous = text[j - 1], current = text[j]
        if !(previous.isLetter || previous.isNumber) { return true }
        return previous.isLowercase && current.isUppercase
    }
}
