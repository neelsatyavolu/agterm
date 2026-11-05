import XCTest
@testable import AgTermCore

final class ReleaseVersionTests: XCTestCase {
    private let ordered = ["1.0.8", "1.0.9", "1.0.10", "1.1.0-beta.1", "1.1.0-beta.2", "1.1.0-beta.10", "1.1.0", "1.1.1-beta.1", "1.2.0"]

    func testParses() {
        XCTAssertEqual(ReleaseVersion("1.0.9")?.numbers, [1, 0, 9])
        XCTAssertNil(ReleaseVersion("1.0.9")?.beta)
        XCTAssertEqual(ReleaseVersion("1.1.0-beta.2")?.beta, 2)
        XCTAssertEqual(ReleaseVersion("1.1.0-beta.2")?.description, "1.1.0-beta.2")
        for bad in ["", "1..0", "1.0-rc.1", "1.0-beta", "1.0-beta.x", "v1.0", "1.0 "] {
            XCTAssertNil(ReleaseVersion(bad), bad)
        }
    }

    func testOrdersBetasBeforeTheirRelease() {
        let versions = ordered.compactMap(ReleaseVersion.init)
        XCTAssertEqual(versions.count, ordered.count)
        XCTAssertEqual(versions, versions.sorted())
        XCTAssertEqual(Set(versions.map(\.description)).count, versions.count)
    }

    func testBundleVersions() {
        XCTAssertEqual(ReleaseVersion("1.0.9")?.bundleVersion, "1.0.9")
        XCTAssertEqual(ReleaseVersion("1.1.0-beta.1")?.bundleVersion, "1.1.0b1")
    }

    /// What Sparkle installs depends on this: each CFBundleVersion must sort after the one before.
    func testSparkleOrdersBundleVersions() {
        let bundle = ordered.compactMap { ReleaseVersion($0)?.bundleVersion }
        for (older, newer) in zip(bundle, bundle.dropFirst()) {
            XCTAssertEqual(SparkleComparator.compare(older, newer), .orderedAscending, "\(older) < \(newer)")
            XCTAssertEqual(SparkleComparator.compare(newer, older), .orderedDescending, "\(newer) > \(older)")
        }
        // Why the mapping exists: Sparkle stops reading at a "-".
        XCTAssertEqual(SparkleComparator.compare("1.1.0-beta.1", "1.1.0"), .orderedSame)
        XCTAssertEqual(SparkleComparator.compare("1.0", "1.0.0"), .orderedSame)
    }
}

/// A port of Sparkle 2.9.6's SUStandardVersionComparator (Sparkle/SUStandardVersionComparator.m),
/// so the test checks the ordering Sparkle applies to CFBundleVersion.
private enum SparkleComparator {
    enum Kind { case number, string, period, punctuation, whitespace, dash }

    static func kind(_ part: String) -> Kind {
        if part == "." { return .period }
        if part == "-" { return .dash }
        let scalar = part.unicodeScalars.first!
        if CharacterSet.decimalDigits.contains(scalar) { return .number }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .whitespace }
        if CharacterSet.punctuationCharacters.contains(scalar) { return .punctuation }
        return .string
    }

    static func isSeparator(_ kind: Kind) -> Bool { [.period, .punctuation, .whitespace].contains(kind) }

    static func sameClass(_ a: Kind, _ b: Kind) -> Bool {
        isSeparator(a) ? isSeparator(b) : a == b
    }

    static func split(_ version: String) -> [String] {
        let chars = version.map(String.init)
        guard let first = chars.first else { return [] }
        var parts: [String] = []
        var current = first
        var old = kind(first)
        for character in chars.dropFirst() {
            let new = kind(character)
            if new == .dash { break }
            if old != new || isSeparator(old) {
                parts.append(current)
                current = character
            } else {
                current += character
            }
            old = new
        }
        parts.append(current)
        return parts
    }

    static func leadingNumberAndPeriodCount(_ parts: [String]) -> Int {
        parts.prefix { [.number, .period].contains(kind($0)) }.count
    }

    static func balance(_ a: inout [String], _ b: inout [String]) {
        let ca = leadingNumberAndPeriodCount(a), cb = leadingNumberAndPeriodCount(b)
        func pad(_ to: inout [String], _ toCount: Int, from: [String], _ fromCount: Int) {
            for i in toCount..<fromCount { to.insert(kind(from[i]) == .period ? "." : "0", at: i) }
        }
        if ca > cb { pad(&b, cb, from: a, ca) } else if cb > ca { pad(&a, ca, from: b, cb) }
    }

    static func compare(_ versionA: String, _ versionB: String) -> ComparisonResult {
        var a = split(versionA), b = split(versionB)
        balance(&a, &b)
        let n = min(a.count, b.count)
        for i in 0..<n {
            let ta = kind(a[i]), tb = kind(b[i])
            if sameClass(ta, tb) {
                if ta == .number {
                    let va = Int64(a[i]) ?? 0, vb = Int64(b[i]) ?? 0
                    if va != vb { return va < vb ? .orderedAscending : .orderedDescending }
                } else if ta == .string, a[i] != b[i] {
                    return a[i] < b[i] ? .orderedAscending : .orderedDescending
                }
            } else if ta != .string, tb == .string {
                return .orderedDescending
            } else if ta == .string, tb != .string {
                return .orderedAscending
            } else {
                return ta == .number ? .orderedDescending : .orderedAscending
            }
        }
        guard a.count != b.count else { return .orderedSame }
        let longerIsA = a.count > b.count
        let missing = longerIsA ? a[n] : b[n]
        // A letter part after the shorter version's end means a pre-release: the shorter wins.
        if kind(missing) == .string { return longerIsA ? .orderedAscending : .orderedDescending }
        return longerIsA ? .orderedDescending : .orderedAscending
    }
}
