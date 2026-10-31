import Foundation

/// A WebSocket client for text messages: the cloud machine's connection to the phone relay.
/// Linux's Foundation can't open WebSockets (its libcurl has none), so TLS comes from
/// `openssl s_client`, which the machine has anyway (ca-certificates needs it): it verifies the
/// relay's certificate and name, and carries the WebSocket over its stdin and stdout, one end of
/// a socketpair. `ws://` URLs connect over plain TCP (tests).
final class RelaySocket: @unchecked Sendable {
    enum Event: Equatable {
        case text(String)
        /// The close code the relay sent, if any.
        case closed(code: Int?)
    }

    private static let openssl = "/usr/bin/openssl"
    private static let handshakeTimeout = 15

    private let fd: Int32
    private let pid: pid_t?
    private let writer = DispatchQueue(label: "agterm.relay-socket")
    private let lock = NSLock()
    private var closed = false
    /// Whether `fd` is still ours; read and written only on `writer`, which does every write
    /// and the close, so nothing touches the number once another connection may reuse it.
    private var isOpen = true
    private var leftover: [UInt8] = []

    /// Connects and does the handshake; blocks, so not for a queue that others wait on.
    init(url: URL) throws {
        guard let host = url.host, ["ws", "wss"].contains(url.scheme) else { throw POSIXError(.EINVAL) }
        let secure = url.scheme == "wss"
        let port = UInt16(url.port ?? (secure ? 443 : 80))
        if secure {
            (fd, pid) = try Self.tls(host: host, port: port)
        } else {
            fd = try TCPSocket.connect(host: host, port: port, timeout: 10)
            pid = nil
        }
        do {
            leftover = try handshake(host: host, target: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? ""))
        } catch {
            shut()
            throw error
        }
    }

    /// Reads on its own thread, handing each message and then the close to `handler` on `queue`.
    func start(on queue: DispatchQueue, _ handler: @escaping (Event) -> Void) {
        let thread = Thread { [self] in
            let code = readMessages { text in queue.async { handler(.text(text)) } }
            shut()
            queue.async { handler(.closed(code: code)) }
        }
        thread.stackSize = 256 * 1024
        thread.start()
    }

    func send(_ text: String) {
        let frame = WebSocketTransport.frame(.text, Array(text.utf8)[...], masked: true)
        writer.async { [self] in
            guard isOpen else { return }
            if !WebSocketTransport.writeAll(fd, frame) { shutdown(fd, Int32(SHUT_RDWR)) }
        }
    }

    /// Ends the connection; the reader then reports `closed`.
    func close() {
        writer.async { [self] in
            guard isOpen else { return }
            _ = WebSocketTransport.writeAll(fd, WebSocketTransport.frame(.close, [][...], masked: true))
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    // MARK: Connecting

    /// `openssl s_client` on one end of a socketpair; returns the other end and its pid.
    private static func tls(host: String, port: UInt16) throws -> (Int32, pid_t) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0 else { throw POSIXError.current }
        pair.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
        defer { if devNull >= 0 { Foundation.close(devNull) } }
        let argv = [openssl, "s_client", "-quiet", "-verify_return_error", "-verify_hostname", host,
                    "-servername", host, "-connect", "\(host):\(port)"]
        do {
            let pid = try ExecSession.spawn(path: openssl, argv: argv, env: ["PATH=/usr/bin:/bin"],
                                            stdio: [pair[1], pair[1], devNull >= 0 ? devNull : pair[1]])
            Foundation.close(pair[1])
            return (pair[0], pid)
        } catch {
            pair.forEach { _ = Foundation.close($0) }
            throw error
        }
    }

    private func handshake(host: String, target: String) throws -> [UInt8] {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var time = timeval(tv_sec: Self.handshakeTimeout, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nUser-Agent: agterm-cloud\r\n\r\n"
        guard WebSocketTransport.writeAll(fd, Array(request.utf8)),
              let (response, rest) = WebSocketTransport.readHeader(fd),
              response.hasPrefix("HTTP/1.1 101"),
              response.lowercased().contains("sec-websocket-accept: \(WebSocketTransport.accept(key).lowercased())")
        else { throw WebSocketTransport.Failure.badHandshake }
        time = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        return rest
    }

    // MARK: Reading

    /// Until the connection ends; returns the close code, if the relay sent one.
    private func readMessages(_ deliver: (String) -> Void) -> Int? {
        var reader = WebSocketTransport.FrameReader()
        reader.append(leftover[...])
        var message: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            do {
                while let (opcode, payload) = try reader.next() {
                    switch opcode {
                    case .text, .binary: message = payload
                    case .continuation: message += payload
                    case .ping:
                        let pong = WebSocketTransport.frame(.pong, payload[...], masked: true)
                        writer.async { [self] in if isOpen { _ = WebSocketTransport.writeAll(fd, pong) } }
                        continue
                    case .pong: continue
                    case .close: return payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : nil
                    }
                    if reader.final {
                        deliver(String(decoding: message, as: UTF8.self))
                        message = []
                    }
                }
            } catch {
                return nil
            }
            let count = Foundation.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            reader.append(buffer[0..<count])
        }
    }

    /// Closes the socket and ends `s_client`, once.
    private func shut() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        writer.async { [self] in
            isOpen = false
            Foundation.close(fd)
        }
        if let pid {
            // SIGKILL: s_client keeps nothing, and it inherits the helper's ignored SIGTERM.
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }
}
