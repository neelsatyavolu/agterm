import Foundation

/// The protocol between the app and `agterm-sessions`, the helper that owns every tab's shell.
/// Frames travel over a Unix socket: 4-byte big-endian length, 1-byte tag, payload.
public enum SessionWire {
    public static let protocolVersion = 1
    /// Largest accepted length field (tag + payload).
    public static let maxFrameLength = 16 * 1024 * 1024
    /// The `error` text a client gets when another client attaches to its session; it must not reattach.
    public static let superseded = "superseded"
}

public struct SpawnRequest: Codable, Equatable {
    public var executable: String
    public var argv: [String]
    /// `KEY=VALUE` entries.
    public var env: [String]
    public var cwd: String
    public var cols: UInt16
    public var rows: UInt16

    public init(executable: String, argv: [String], env: [String], cwd: String, cols: UInt16, rows: UInt16) {
        self.executable = executable
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
    }
}

public struct SessionInfo: Codable, Equatable {
    public var id: String
    public var pid: Int32
    public var cwd: String
    public var startedAt: Date
    /// A client is showing it (another agterm, say). Helpers from before this field send none,
    /// which reads as false; older apps ignore it.
    public var attached: Bool

    public init(id: String, pid: Int32, cwd: String, startedAt: Date, attached: Bool = false) {
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.startedAt = startedAt
        self.attached = attached
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pid = try c.decode(Int32.self, forKey: .pid)
        cwd = try c.decode(String.self, forKey: .cwd)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        attached = try c.decodeIfPresent(Bool.self, forKey: .attached) ?? false
    }
}

public enum WireMessage: Equatable {
    case hello(version: Int, build: String)
    case list
    case sessions([SessionInfo])
    case spawn(SpawnRequest)
    case attach(id: String)
    case attached(SessionInfo)
    /// Screen history sent right after `attached`; raw bytes.
    case replay(Data)
    /// Live terminal bytes; raw.
    case output(Data)
    case exited(id: String, status: Int32)
    case kill(id: String, signal: Int32)
    case shutdownIfIdle
    case error(String)
}

public enum WireFrameError: Error, Equatable {
    case frameTooLarge(Int)
    case unknownTag(UInt8)
    case badPayload
}

public enum WireFrame {
    /// Tags are a contract between app and helper versions: never renumber, only add.
    private enum Tag: UInt8 {
        case hello = 1, list = 2, sessions = 3, spawn = 4, attach = 5, attached = 6
        case replay = 7, output = 8, exited = 9, kill = 10, shutdownIfIdle = 11, error = 12
    }

    private struct Hello: Codable { var version: Int; var build: String }
    private struct SessionID: Codable { var id: String }
    private struct Exited: Codable { var id: String; var status: Int32 }
    private struct Kill: Codable { var id: String; var signal: Int32 }

    /// Largest payload one frame can carry. Senders split larger `output` and `replay` data
    /// into several frames, which receivers feed in order.
    public static let maxPayload = SessionWire.maxFrameLength - 1

    public static func encode(_ m: WireMessage) -> Data {
        let (tag, payload) = parts(of: m)
        precondition(payload.count <= maxPayload, "wire payload of \(payload.count) bytes exceeds \(maxPayload)")
        var frame = Data(capacity: 5 + payload.count)
        let length = UInt32(1 + payload.count)
        for shift in stride(from: 24, through: 0, by: -8) { frame.append(UInt8((length >> UInt32(shift)) & 0xff)) }
        frame.append(tag.rawValue)
        frame.append(payload)
        return frame
    }

    /// Takes one complete frame off the front of `buffer`. Returns nil, leaving `buffer` alone, while the frame is incomplete.
    /// After any throw the caller must drop the connection: the buffer is left as-is, so retrying would fail forever.
    public static func decode(_ buffer: inout Data) throws -> WireMessage? {
        let base = buffer.startIndex
        guard buffer.count >= 4 else { return nil }
        let length = buffer[base..<base + 4].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= SessionWire.maxFrameLength else { throw WireFrameError.frameTooLarge(length) }
        guard length >= 1 else { throw WireFrameError.badPayload }
        guard buffer.count >= 4 + length else { return nil }
        let rawTag = buffer[base + 4]
        guard let tag = Tag(rawValue: rawTag) else { throw WireFrameError.unknownTag(rawTag) }
        let payload = Data(buffer[base + 5..<base + 4 + length])
        let message = try message(tag: tag, payload: payload)
        buffer.removeSubrange(base..<base + 4 + length)
        return message
    }

    private static func parts(of m: WireMessage) -> (Tag, Data) {
        switch m {
        case .hello(let version, let build): return (.hello, json(Hello(version: version, build: build)))
        case .list: return (.list, Data())
        case .sessions(let infos): return (.sessions, json(infos))
        case .spawn(let request): return (.spawn, json(request))
        case .attach(let id): return (.attach, json(SessionID(id: id)))
        case .attached(let info): return (.attached, json(info))
        case .replay(let bytes): return (.replay, bytes)
        case .output(let bytes): return (.output, bytes)
        case .exited(let id, let status): return (.exited, json(Exited(id: id, status: status)))
        case .kill(let id, let signal): return (.kill, json(Kill(id: id, signal: signal)))
        case .shutdownIfIdle: return (.shutdownIfIdle, Data())
        case .error(let text): return (.error, Data(text.utf8))
        }
    }

    private static func message(tag: Tag, payload: Data) throws -> WireMessage {
        switch tag {
        case .hello: let h: Hello = try object(payload); return .hello(version: h.version, build: h.build)
        case .list: return .list
        case .sessions: return .sessions(try object(payload))
        case .spawn: return .spawn(try object(payload))
        case .attach: return .attach(id: try object(payload, as: SessionID.self).id)
        case .attached: return .attached(try object(payload))
        case .replay: return .replay(payload)
        case .output: return .output(payload)
        case .exited: let e: Exited = try object(payload); return .exited(id: e.id, status: e.status)
        case .kill: let k: Kill = try object(payload); return .kill(id: k.id, signal: k.signal)
        case .shutdownIfIdle: return .shutdownIfIdle
        case .error: return .error(String(decoding: payload, as: UTF8.self))
        }
    }

    private static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // These types always encode; an empty payload would fail decode loudly rather than corrupt state.
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func object<T: Decodable>(_ payload: Data, as type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: payload) } catch { throw WireFrameError.badPayload }
    }
}
