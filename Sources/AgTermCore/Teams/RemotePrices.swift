import Foundation

/// The price list agterm and agmux download (`prices.json` at the root of the agterm repo), so a
/// new model gets a price without an app update. Its rows win over the built-in table.
///
/// ```json
/// {"version": 1, "updated": "2026-11-09", "models": [
///   {"ids": ["claude-fable-5-2"], "input": 8, "output": 40, "cacheRead": 0.2, "cacheWrite": 10}]}
/// ```
/// USD per million tokens; `cacheWrite` is Claude's 5-minute write rate (1-hour writes stay at
/// twice input). IDs are matched as the built-in table matches them.
public enum RemotePrices {
    public static let url = URL(string: "https://raw.githubusercontent.com/neelsatyavolu/agterm/main/prices.json")!

    public enum ParseError: Error, Equatable {
        case notAPriceList, unsupportedVersion, badRow(Int)
    }

    /// Model key to rates. Throws on anything malformed, so a broken file never zeroes a price.
    static func parse(_ data: Data) throws -> [String: Rates] {
        guard let root = JSONValue.parse(data: data), root.isObject, let rows = root["models"]?.array else {
            throw ParseError.notAPriceList
        }
        guard root["version"]?.int == 1 else { throw ParseError.unsupportedVersion }
        var out: [String: Rates] = [:]
        for (index, row) in rows.enumerated() {
            func price(_ key: String) throws -> Double {
                guard let value = row[key]?.number, value.isFinite, value >= 0 else { throw ParseError.badRow(index) }
                return value
            }
            guard let ids = row["ids"]?.array?.compactMap(\.string), !ids.isEmpty else { throw ParseError.badRow(index) }
            let rates = Rates(input: try price("input"), output: try price("output"),
                              cacheRead: try price("cacheRead"), cacheWrite: try price("cacheWrite"))
            for id in ids { out[PriceTable.key(id)] = rates }
        }
        return out
    }
}
