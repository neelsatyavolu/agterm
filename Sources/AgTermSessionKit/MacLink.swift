#if canImport(Network)
import CryptoKit
import Foundation
import Network

/// The encrypted link between two Macs (Settings → Macs): TLS 1.2 with a key both sides derive
/// from the pairing secret, so there are no certificates to make or trust, and a Mac without
/// the secret can't finish the handshake. Over it go plain `SessionWire` frames to the worker's
/// gateway, which still wants `auth` with a token from the same secret.
public enum MacLink {
    public static let serviceType = "_agterm-mac._tcp"
    public static let secretVariable = "AGTERM_MAC_SECRET"
    public static let defaultPort: UInt16 = 47821

    /// The gateway token for `secret`, 64 hex digits.
    public static func token(secret: String) -> String {
        key(secret, label: "agterm-mac-token").map { String(format: "%02x", $0) }.joined()
    }

    static func key(_ secret: String, label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }

    static func parameters(secret: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let psk = key(secret, label: "agterm-mac-psk").withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("agterm-mac".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        return NWParameters(tls: tls, tcp: tcp)
    }

    public struct ConnectError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// Tries every endpoint at once (the Bonjour name and the host and port) and returns a
    /// socket carrying the decrypted stream of the first to connect. Throws with a reason if
    /// none does within `timeout`.
    public static func connect(_ endpoints: [NWEndpoint], secret: String, timeout: TimeInterval) throws -> Int32 {
        let queue = DispatchQueue(label: "agterm.mac-link")
        let settled = DispatchSemaphore(value: 0)
        let connections = endpoints.map { NWConnection(to: $0, using: parameters(secret: secret)) }
        // Used on `queue` only.
        var winner: NWConnection?
        var failures: [NWError] = []
        var open = connections.count
        for connection in connections {
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    guard winner == nil else { return }
                    winner = connection
                    settled.signal()
                case .failed(let error), .waiting(let error):
                    // Waiting would retry later; a refused port or a wrong key won't change.
                    finished = true
                    failures.append(error)
                    open -= 1
                    if open == 0, winner == nil { settled.signal() }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        if connections.isEmpty { settled.signal() }
        _ = settled.wait(timeout: .now() + timeout)
        let (chosen, reasons) = queue.sync { () -> (NWConnection?, [NWError]) in
            for connection in connections where connection !== winner {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            winner?.stateUpdateHandler = nil
            return (winner, failures)
        }
        if let chosen { return try MacLinkBridge.socket(for: chosen, queue: queue) }
        let reason = reasons.first { if case .tls = $0 { return true } else { return false } } ?? reasons.last
        throw ConnectError(description: reason.map(describe) ?? "no answer in \(Int(timeout)) s")
    }

    private static func describe(_ error: NWError) -> String {
        if case .tls = error { return "the pairing code doesn't match (\(error))" }
        return "\(error)"
    }

    /// The endpoints for a paired Mac: its Bonjour service first, then `host:port`.
    public static func endpoints(name: String, host: String, port: UInt16) -> [NWEndpoint] {
        var endpoints: [NWEndpoint] = [.service(name: name, type: serviceType, domain: "local.", interface: nil)]
        if let port = NWEndpoint.Port(rawValue: port) { endpoints.append(.hostPort(host: NWEndpoint.Host(host), port: port)) }
        return endpoints
    }
}

/// Listens for paired Macs on the worker and hands each decrypted stream to `accept`.
public final class MacListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agterm.mac-listener")

    /// `serviceName` advertises it with Bonjour; nil doesn't (tests, loopback).
    public init(port: UInt16, secret: String, serviceName: String?, accept: @escaping (Int32) -> Void) throws {
        let parameters = MacLink.parameters(secret: secret)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        if let serviceName { listener.service = NWListener.Service(name: serviceName, type: MacLink.serviceType) }
        listener.newConnectionHandler = { connection in
            // Its own queue: a client whose command isn't reading blocks only its own writes.
            let queue = DispatchQueue(label: "agterm.mac-link")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    if let fd = try? MacLinkBridge.socket(for: connection, queue: queue) { accept(fd) } else { connection.cancel() }
                case .failed, .waiting: connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Waits until it listens; throws if the port can't be had.
    public func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error):
                failure = error
                ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else { throw MacLink.ConnectError(description: "listener didn't start") }
        if let failure = queue.sync(execute: { failure }) {
            listener.cancel()
            throw failure
        }
    }

    public var port: UInt16 { listener.port?.rawValue ?? 0 }

    public func stop() {
        listener.cancel()
    }
}

/// Moves bytes between a ready connection and one end of a socketpair, so `WireConnection`
/// can use it like any socket; either side closing closes both. Up to `inFlight` chunks go out unconfirmed; writes to the socket
/// block the connection's queue until the reader catches up, which is the backpressure.
final class MacLinkBridge: @unchecked Sendable {
    private static let chunk = 64 * 1024
    private static let inFlight = 16

    private let connection: NWConnection
    private let inner: Int32
    private let lock = NSLock()
    private var ended = false
    private var loops = 2

    /// The other end of the pair, for the caller.
    static func socket(for connection: NWConnection, queue: DispatchQueue) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError.current }
        var on: Int32 = 1
        for fd in pair {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let bridge = MacLinkBridge(connection: connection, inner: pair[1])
        connection.stateUpdateHandler = { state in
            if case .failed = state { bridge.end() }
            if case .cancelled = state { bridge.end() }
        }
        bridge.receive()
        Thread.detachNewThread { bridge.sendLoop() }
        return pair[0]
    }

    private init(connection: NWConnection, inner: Int32) {
        self.connection = connection
        self.inner = inner
    }

    /// Network → socket.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty, !WebSocketTransport.writeAll(inner, [UInt8](data)) {
                end()
                return finish()
            }
            if error != nil {
                end()
                return finish()
            }
            if isComplete {
                // The other Mac is done sending; what this side still sends goes on.
                shutdown(inner, SHUT_WR)
                return finish()
            }
            receive()
        }
    }

    /// Socket → network.
    private func sendLoop() {
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        let slots = DispatchSemaphore(value: 0)
        for _ in 0..<Self.inFlight { slots.signal() }
        while true {
            let count = read(inner, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                // The socket's owner hung up: what was sent goes out, then the link closes
                // (nothing over it uses half-closed streams).
                for _ in 0..<Self.inFlight { slots.wait() }
                end()
                connection.cancel()
                return finish()
            }
            slots.wait()
            guard !isEnded else { return finish() }
            connection.send(content: Data(buffer[0..<count]), completion: .contentProcessed { [self] error in
                if error != nil { end() }
                slots.signal()
            })
        }
    }

    private var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    /// Either side failed: both loops stop.
    private func end() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        guard first else { return }
        shutdown(inner, SHUT_RDWR)
    }

    /// A loop is done; the last one cancels the connection and closes the socket.
    private func finish() {
        lock.lock()
        loops -= 1
        let last = loops == 0
        lock.unlock()
        guard last else { return }
        end()
        connection.cancel()
        close(inner)
    }
}
#endif
