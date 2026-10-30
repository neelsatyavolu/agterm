import Foundation

/// The gateway's transport. Fly's proxy picks a user's machine (`fly-force-instance-id`) only for
/// HTTP services, so `SessionWire` travels inside a WebSocket (RFC 6455): each binary message
/// carries any run of the frame stream. `serve` and `connect` do the handshake, then hand back one
/// end of a socketpair carrying the plain stream, so `WireConnection` works unchanged; two threads
/// move the bytes until either side closes, blocking, which is the backpressure.
public enum WebSocketTransport {
    /// Largest message accepted; senders here never exceed `chunk`.
    static let maxMessage = 16 * 1024 * 1024 + 64
    static let chunk = 64 * 1024
    private static let maxHeader = 16 * 1024
    private static let handshakeTimeout: Int = 10

    public enum Failure: Error, Equatable {
        case badHandshake
        case badFrame
    }

    /// Server side, for an accepted TCP connection. A plain `GET /health` gets `ok` (Fly's health
    /// check); anything else that isn't a WebSocket upgrade is refused. `ready` gets the stream's
    /// socket, on the connection's own thread.
    public static func serve(_ tcp: Int32, ready: @escaping (Int32) -> Void) {
        Thread.detachNewThread {
            setBlocking(tcp, timeout: handshakeTimeout)
            guard let (request, rest) = readHeader(tcp) else { return _ = Foundation.close(tcp) }
            switch HandshakeRequest(request) {
            case .health:
                writeAll(tcp, Array("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n".utf8))
                Foundation.close(tcp)
            case .upgrade(let key):
                writeAll(tcp, Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(accept(key))\r\n\r\n").utf8))
                setBlocking(tcp, timeout: 0)
                pump(tcp, leftover: rest, masking: false, ready: ready)
            case .invalid:
                writeAll(tcp, Array("HTTP/1.1 426 Upgrade Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                Foundation.close(tcp)
            }
        }
    }

    /// Client side, over a connected TCP socket (tests, and tools without URLSession). Blocks for
    /// the handshake; returns the stream's socket.
    public static func connect(_ tcp: Int32, host: String, path: String = "/", headers: [String: String] = [:]) throws -> Int32 {
        setBlocking(tcp, timeout: handshakeTimeout)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        writeAll(tcp, Array(("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\(extra)\r\n").utf8))
        guard let (response, rest) = readHeader(tcp), response.hasPrefix("HTTP/1.1 101"),
              response.lowercased().contains("sec-websocket-accept: \(accept(key).lowercased())") else {
            Foundation.close(tcp)
            throw Failure.badHandshake
        }
        setBlocking(tcp, timeout: 0)
        var stream: Int32 = -1
        pump(tcp, leftover: rest, masking: true) { stream = $0 }
        return stream
    }

    // MARK: Handshake

    enum HandshakeRequest: Equatable {
        case upgrade(key: String)
        case health
        case invalid

        init(_ header: String) {
            let lines = header.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            guard requestLine.count == 3, requestLine[0] == "GET" else { self = .invalid; return }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if fields["upgrade"]?.lowercased() == "websocket",
               fields["connection"]?.lowercased().contains("upgrade") == true,
               fields["sec-websocket-version"] == "13", let key = fields["sec-websocket-key"], !key.isEmpty {
                self = .upgrade(key: key)
            } else {
                self = requestLine[1] == "/health" ? .health : .invalid
            }
        }
    }

    static func accept(_ key: String) -> String {
        Data(SHA1.hash(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// The header up to its blank line, and whatever came after it.
    private static func readHeader(_ fd: Int32) -> (String, [UInt8])? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end: [UInt8] = [13, 10, 13, 10]
        while bytes.count < maxHeader {
            let count = Foundation.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            bytes += buffer[0..<count]
            if let range = bytes.firstRange(of: end) {
                return (String(decoding: bytes[..<range.lowerBound], as: UTF8.self), Array(bytes[range.upperBound...]))
            }
        }
        return nil
    }

    // MARK: Frames

    enum Opcode: UInt8 {
        case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
    }

    /// One frame, final, masked when sent by a client (RFC 6455 §5.2).
    static func frame(_ opcode: Opcode, _ payload: ArraySlice<UInt8>, masked: Bool) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode.rawValue]
        let mask: UInt8 = masked ? 0x80 : 0
        switch payload.count {
        case ..<126: out.append(mask | UInt8(payload.count))
        case ..<65536: out += [mask | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
        default: out.append(mask | 127); out += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> UInt64($0 * 8)) & 0xff) }
        }
        guard masked else { return out + payload }
        let key = (0..<4).map { _ in UInt8.random(in: 0...255) }
        out += key
        out += payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
        return out
    }

    /// Takes frames off a byte stream.
    struct FrameReader {
        private var buffer: [UInt8] = []
        private var start = 0

        mutating func append(_ bytes: ArraySlice<UInt8>) {
            if start > 0, start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
            buffer += bytes
        }

        /// The next complete frame's opcode and unmasked payload, nil until one is complete.
        mutating func next() throws -> (Opcode, [UInt8])? {
            let available = buffer.count - start
            guard available >= 2 else { return nil }
            let first = buffer[start], second = buffer[start + 1]
            guard first & 0x70 == 0, let opcode = Opcode(rawValue: first & 0x0f) else { throw Failure.badFrame }
            var offset = 2
            var length = Int(second & 0x7f)
            if length >= 126 {
                let size = length == 126 ? 2 : 8
                guard available >= 2 + size else { return nil }
                length = (0..<size).reduce(0) { $0 << 8 | Int(buffer[start + 2 + $1]) }
                offset += size
            }
            guard length <= WebSocketTransport.maxMessage else { throw Failure.badFrame }
            let masked = second & 0x80 != 0
            let keyStart = start + offset
            if masked { offset += 4 }
            guard available >= offset + length else { return nil }
            var payload = Array(buffer[(start + offset)..<(start + offset + length)])
            if masked {
                for i in payload.indices { payload[i] ^= buffer[keyStart + i % 4] }
            }
            start += offset + length
            if start > 1024 * 1024 { buffer.removeFirst(start); start = 0 }
            return (opcode, payload)
        }
    }

    // MARK: Pumping

    /// Hands `ready` the stream's end of a socketpair, then moves bytes both ways on two threads.
    /// The last thread out closes the TCP socket and its end of the pair.
    private static func pump(_ tcp: Int32, leftover: [UInt8], masking: Bool, ready: (Int32) -> Void) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0 else { return _ = Foundation.close(tcp) }
        pair.forEach { UnixSocket.configure($0) }
        let (stream, inner) = (pair[0], pair[1])
        let state = PumpState(tcp: tcp, inner: inner)
        ready(stream)
        Thread.detachNewThread { networkToStream(state, leftover: leftover, masking: masking) }
        Thread.detachNewThread { streamToNetwork(state, masking: masking) }
    }

    /// Shared by a connection's two threads.
    private final class PumpState: @unchecked Sendable {
        let tcp: Int32
        let inner: Int32
        private let lock = NSLock()
        private var running = 2

        init(tcp: Int32, inner: Int32) {
            self.tcp = tcp
            self.inner = inner
        }

        /// Frames from both threads (data, pongs, close) mustn't interleave.
        func send(_ bytes: [UInt8]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return writeAll(tcp, bytes)
        }

        /// Called once by each thread as it ends; stops the other one too.
        func finished() {
            shutdown(tcp, Int32(SHUT_RDWR))
            shutdown(inner, Int32(SHUT_RDWR))
            lock.lock()
            running -= 1
            let last = running == 0
            lock.unlock()
            guard last else { return }
            Foundation.close(tcp)
            Foundation.close(inner)
        }
    }

    private static func networkToStream(_ state: PumpState, leftover: [UInt8], masking: Bool) {
        defer { state.finished() }
        var reader = FrameReader()
        reader.append(leftover[...])
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            do {
                while let (opcode, payload) = try reader.next() {
                    switch opcode {
                    case .binary, .continuation, .text:
                        guard writeAll(state.inner, payload) else { return }
                    case .ping:
                        guard state.send(frame(.pong, payload[...], masked: masking)) else { return }
                    case .pong:
                        break
                    case .close:
                        _ = state.send(frame(.close, [][...], masked: masking))
                        return
                    }
                }
            } catch {
                return
            }
            let count = Foundation.read(state.tcp, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            reader.append(buffer[0..<count])
        }
    }

    private static func streamToNetwork(_ state: PumpState, masking: Bool) {
        defer { state.finished() }
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = Foundation.read(state.inner, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                _ = state.send(frame(.close, [][...], masked: masking))
                return
            }
            guard state.send(frame(.binary, buffer[0..<count], masked: masking)) else { return }
        }
    }

    // MARK: Descriptors

    /// Blocking, with a receive timeout in seconds (0: none). Accepted sockets inherit the
    /// listener's non-blocking mode on macOS but not on Linux.
    private static func setBlocking(_ fd: Int32, timeout seconds: Int) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Foundation.send(fd, $0.baseAddress! + offset, bytes.count - offset, sendFlags) }
            if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    #if canImport(Darwin)
    private static let sendFlags: Int32 = 0
    #else
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
}
