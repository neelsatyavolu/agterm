import Foundation

/// A release number as VERSION and CHANGELOG.md write it: `1.0.9` (stable) or `1.1.0-beta.2`.
/// A beta comes before the stable release of the same number.
public struct ReleaseVersion: Comparable, CustomStringConvertible {
    public let numbers: [Int]
    /// The N of `-beta.N`; nil for a stable release.
    public let beta: Int?

    /// Nil unless the text is dot-separated numbers, optionally followed by `-beta.N`.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.numbers = numbers.map { $0! }
        if parts.count == 2 {
            guard parts[1].hasPrefix("beta."), let n = Int(parts[1].dropFirst(5)), n >= 0 else { return nil }
            beta = n
        } else {
            beta = nil
        }
    }

    public var isBeta: Bool { beta != nil }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (beta.map { "-beta.\($0)" } ?? "")
    }

    /// CFBundleVersion for Sparkle, which orders updates by it: `1.1.0-beta.2` becomes `1.1.0b2`.
    /// Sparkle's SUStandardVersionComparator ignores everything after a "-", so `1.1.0-beta.2`
    /// would equal `1.1.0`; a letter part sorts before the end of the version, so `1.1.0b2` comes
    /// after `1.1.0b1` and before `1.1.0`. scripts/bundle.sh makes the same change with sed.
    public var bundleVersion: String {
        numbers.map(String.init).joined(separator: ".") + (beta.map { "b\($0)" } ?? "")
    }

    /// Numeric per component, missing ones counting as 0; then a beta before its stable release.
    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let l = i < a.numbers.count ? a.numbers[i] : 0
            let r = i < b.numbers.count ? b.numbers[i] : 0
            if l != r { return l < r }
        }
        switch (a.beta, b.beta) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        default: return false
        }
    }

    /// `1.0` equals `1.0.0`, as in `<`.
    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { !(a < b) && !(b < a) }
}
