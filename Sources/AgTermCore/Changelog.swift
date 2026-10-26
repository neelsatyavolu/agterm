import Foundation

/// One bullet in a release: `- Added: text`. `text` excludes the prefix.
public struct Item: Equatable {
    public enum Kind: Equatable { case added, fixed, changed, other }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// One `## version — date` section of CHANGELOG.md.
public struct Release: Equatable {
    public var version: String
    public var date: String?
    public var items: [Item]

    public init(version: String, date: String?, items: [Item]) {
        self.version = version
        self.date = date
        self.items = items
    }
}

/// Reads CHANGELOG.md (newest section first) and picks the releases a user hasn't seen.
public enum Changelog {
    private static let prefixes: [(String, Item.Kind)] = [
        ("Added:", .added), ("Fixed:", .fixed), ("Changed:", .changed),
    ]

    /// Sections start at `## version — date`; anything before the first one is ignored.
    public static func parse(_ markdown: String) -> [Release] {
        var releases: [Release] = []
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let heading = line.dropFirst(3).components(separatedBy: " — ")
                let version = heading[0].trimmingCharacters(in: .whitespaces)
                let date = heading.count > 1 ? heading[1].trimmingCharacters(in: .whitespaces) : nil
                releases.append(Release(version: version, date: date, items: []))
            } else if line.hasPrefix("- "), !releases.isEmpty {
                releases[releases.count - 1].items.append(item(String(line.dropFirst(2))))
            }
        }
        return releases
    }

    /// Releases newer than `lastSeen` up to `current`, in the order given. Empty on first install.
    public static func unseen(_ releases: [Release], lastSeen: String?, current: String) -> [Release] {
        guard let lastSeen else { return [] }
        return releases.filter {
            compare($0.version, lastSeen) == .orderedDescending
                && compare($0.version, current) != .orderedDescending
        }
    }

    /// Numeric per dot-component; missing components count as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func item(_ text: String) -> Item {
        for (prefix, kind) in prefixes where text.hasPrefix(prefix) {
            return Item(kind: kind, text: text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        return Item(kind: .other, text: text)
    }
}
