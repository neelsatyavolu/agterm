import Foundation

/// A protobuf message read without its schema: each field number with its raw values. Enough
/// for Antigravity's conversation steps, whose numbers were read off real files (see
/// `AgyTimeline`). Malformed bytes give an empty message rather than a crash.
struct ProtoFields {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed(UInt64)
    }

    private(set) var fields: [(number: Int, value: Value)] = []

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        var out: [(Int, Value)] = []
        defer { fields = out }
        while index < bytes.count {
            guard let key = Self.varint(bytes, &index) else { return }
            let number = Int(key >> 3)
            guard number > 0 else { return }
            switch key & 7 {
            case 0:
                guard let value = Self.varint(bytes, &index) else { return }
                out.append((number, .varint(value)))
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard index + size <= bytes.count else { return }
                var value: UInt64 = 0
                for offset in (0..<size).reversed() { value = value << 8 | UInt64(bytes[index + offset]) }
                index += size
                out.append((number, .fixed(value)))
            case 2:
                guard let length = Self.varint(bytes, &index), length <= UInt64(bytes.count - index) else { return }
                out.append((number, .bytes(Data(bytes[index..<index + Int(length)]))))
                index += Int(length)
            default:
                return
            }
        }
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
        return nil
    }

    func all(_ number: Int) -> [Value] { fields.filter { $0.number == number }.map(\.value) }

    func int(_ number: Int) -> Int? {
        for case .varint(let value) in all(number) { return Int(truncatingIfNeeded: value) }
        return nil
    }

    func data(_ number: Int) -> Data? {
        for case .bytes(let data) in all(number) { return data }
        return nil
    }

    func string(_ number: Int) -> String? {
        data(number).flatMap { String(data: $0, encoding: .utf8) }
    }

    func message(_ number: Int) -> ProtoFields? { data(number).map(ProtoFields.init) }

    func messages(_ number: Int) -> [ProtoFields] {
        all(number).compactMap { if case .bytes(let data) = $0 { ProtoFields(data) } else { nil } }
    }

    /// Follows a path of nested messages: `nested(5, 1)` is field 1 of field 5.
    func nested(_ path: Int...) -> ProtoFields? {
        path.reduce(Optional(self)) { $0?.message($1) }
    }
}
