import Foundation

/// Path-free labels for Teams uploads: project keys and server-bounded strings.
///
/// A path is never sent, and neither is a parent directory.
enum TeamsLabels {
    /// Reduces a working directory to something safe to upload.
    ///
    /// Public repos keep their basename (at most 64 characters) because managers
    /// need to recognise the project; private ones become a short stable hash.
    static func projectKey(workDir: String, private isPrivate: Bool) -> String {
        let separators: Set<Character> = ["/", "\\"]
        var trimmedEnd = Substring(workDir)
        while let last = trimmedEnd.last, separators.contains(last) { trimmedEnd = trimmedEnd.dropLast() }
        let lastComponent = trimmedEnd.split(omittingEmptySubsequences: false, whereSeparator: separators.contains).last ?? ""
        let basename = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if basename.isEmpty { return "" }
        if isPrivate { return shortHash(workDir) }
        // Defence in depth: a basename never contains a separator, but hash rather than leak one.
        if basename.contains(where: separators.contains) { return shortHash(workDir) }
        return String(String.UnicodeScalarView(basename.unicodeScalars.prefix(64)))
    }

    /// Short, stable, non-reversible label: the first 4 bytes of SHA-256, in hex.
    static func shortHash(_ input: String) -> String {
        SHA256.digest(Array(input.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The service's label rule applied before grouping: trimmed, empty when it
    /// holds a path separator, and cut to `maxUnits` UTF-16 code units. Grouping on
    /// the raw label could let two buckets collapse to one key at upload, and the
    /// second absolute upsert would silently replace the first.
    static func wireLabel(_ raw: String, maxUnits: Int) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("/") || text.contains("\\") { return "" }
        var units = 0
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            units += scalar.utf16.count
            if units > maxUnits { break }
            kept.append(scalar)
        }
        return String(kept)
    }
}

/// Minimal SHA-256 (FIPS 180-4), so the core stays Foundation-only.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message + [0x80]
        while padded.count % 64 != 56 { padded.append(0) }
        let bitLength = UInt64(message.count) * 8
        padded += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitLength >> (UInt64($0) * 8)) }

        for start in stride(from: 0, to: padded.count, by: 64) {
            var w = (0..<16).map { i in
                padded[(start + i * 4)..<(start + i * 4 + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w.append(w[i - 16] &+ s0 &+ w[i - 7] &+ s1)
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
        }
        return h.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) } }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
}
