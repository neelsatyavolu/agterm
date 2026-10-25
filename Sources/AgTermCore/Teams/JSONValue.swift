import Foundation

/// A parsed JSON value with the lookups the transcript readers need.
///
/// The accessors mirror serde_json's: `int` only answers for integer numbers,
/// `string` only for strings, and a present `null` is distinct from a missing key
/// (`pointer` returns `.null` for the former and nil for the latter).
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses one JSON document, or nil when the text is not valid JSON.
    static func parse(_ text: some StringProtocol) -> JSONValue? {
        parse(data: Data(text.utf8))
    }

    static func parse(data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(foundation: raw)
    }

    private init?(foundation raw: Any) {
        switch raw {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else if let exact = Int(exactly: number.int64Value), number.int64Value.description == number.stringValue {
                self = .int(exact)
            } else {
                // Integers beyond Int64 (serde's u64 range) are kept as numbers only.
                self = .double(number.doubleValue)
            }
        case let text as String:
            self = .string(text)
        case let items as [Any]:
            self = .array(items.compactMap(JSONValue.init(foundation:)))
        case let fields as [String: Any]:
            self = .object(fields.compactMapValues(JSONValue.init(foundation:)))
        default:
            return nil
        }
    }

    /// Member of an object; nil for a missing key or a non-object.
    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    /// JSON-pointer lookup over object keys, e.g. `"/message/usage"`.
    func pointer(_ path: String) -> JSONValue? {
        path.split(separator: "/").reduce(Optional(self)) { node, key in node?[String(key)] }
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var int: Int? {
        if case .int(let n) = self { return n }
        return nil
    }

    /// serde_json `as_u64`: a non-negative integer.
    var unsigned: Int? {
        guard let n = int, n >= 0 else { return nil }
        return n
    }

    /// serde_json `as_f64`: any number.
    var number: Double? {
        switch self {
        case .int(let n): return Double(n)
        case .double(let d): return d
        default: return nil
        }
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var isObject: Bool { object != nil }
}

/// Splits text into lines the way Rust's `str::lines` does: on `\n`, dropping a
/// trailing `\r` from each line and the empty piece after a final newline.
func rustLines(_ text: String) -> [String] {
    var pieces = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
    if pieces.last?.isEmpty == true { pieces.removeLast() }
    return pieces.map { piece in
        let trimmed = piece.last == 0x0D ? piece.dropLast() : piece
        return String(decoding: trimmed, as: UTF8.self)
    }
}

/// ASCII-only lowercasing, as Rust's `to_ascii_lowercase`.
func asciiLowercased(_ text: String) -> String {
    String(decoding: text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
}

/// Byte-wise string ordering, as Rust's `str` comparison.
func byteLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}
