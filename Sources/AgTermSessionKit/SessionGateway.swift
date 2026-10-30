import AgTermCore
import Foundation

/// Lets an app on another machine use this sessions helper (cloud sessions). A TCP client
/// opens with `auth`; with the right token the gateway opens its own connection to the
/// helper's socket and passes frames both ways. The client never gets a pty descriptor
/// (the gateway closes the ones the helper passes), so it types with `input` and resizes with
/// `resize`. Spawns run this machine's login shell (`RemoteSpawn`). TLS is the host's job:
/// listen on loopback and put a TLS proxy (or an SSH tunnel) in front.
public final class SessionGateway {
    /// How long a new connection has to send `auth`.
    public var authTimeout: TimeInterval = 10
    /// Backpressure: past this many unsent bytes to a client, the helper's side isn't read
    /// until it is down to `resumeAt`, so the helper in turn throttles the shell.
    fileprivate static let pauseAbove = 4 * 1024 * 1024
    fileprivate static let resumeAt = 1 * 1024 * 1024

    private let socketPath: String
    private let host: String
    private let requestedPort: UInt16
    private let token: [UInt8]
    private let account: RemoteSpawn.Account
    private let queue = DispatchQueue(label: "agterm.gateway")
    private var listener: DispatchSourceRead?
    private var bridges: [ObjectIdentifier: Bridge] = [:]
    /// The port it listens on, once started.
    public private(set) var port: UInt16 = 0

    public convenience init(socketPath: String, host: String, port: UInt16, token: String) {
        self.init(socketPath: socketPath, host: host, port: port, token: token, account: .current)
    }

    init(socketPath: String, host: String, port: UInt16, token: String, account: RemoteSpawn.Account) {
        self.socketPath = socketPath
        self.host = host
        requestedPort = port
        self.token = Array(token.utf8)
        self.account = account
    }

    public func start() throws {
        try queue.sync {
            let (fd, port) = try TCPSocket.listen(host: host, port: requestedPort)
            self.port = port
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(fd) }
            source.setCancelHandler { close(fd) }
            listener = source
            source.resume()
        }
    }

    /// Stops listening and drops every client. Not for use on the gateway's queue.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            bridges.values.forEach { $0.close() }
            bridges = [:]
        }
    }

    private func acceptAll(_ listenFd: Int32) {
        while true {
            let fd = accept(listenFd, nil, nil)
            guard fd >= 0 else { return }
            TCPSocket.configure(fd)
            let bridge = Bridge(remote: WireConnection(fd: fd), gateway: self)
            bridges[ObjectIdentifier(bridge)] = bridge
            bridge.start(queue: queue, authTimeout: authTimeout)
        }
    }

    fileprivate func accepts(_ offered: String) -> Bool {
        let offered = Array(offered.utf8)
        guard !token.isEmpty, offered.count == token.count else { return false }
        // Constant time, so the reply's timing says nothing about how much matched.
        return zip(offered, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    fileprivate func openHelper() throws -> WireConnection {
        try WireConnection.connect(path: socketPath)
    }

    fileprivate func localize(_ request: SpawnRequest) -> SpawnRequest {
        RemoteSpawn.localize(request, for: account)
    }

    fileprivate func exec(_ argv: [String], for client: WireConnection) throws -> ExecSession {
        try ExecSession(argv: argv, env: account.environment, client: client, queue: queue)
    }

    fileprivate func ended(_ bridge: Bridge) {
        bridges[ObjectIdentifier(bridge)] = nil
    }
}

/// One network client and its connection to the helper. Used only on the gateway's queue.
private final class Bridge {
    private let remote: WireConnection
    private var local: WireConnection?
    private weak var gateway: SessionGateway?
    private var closed = false
    /// The connection runs a command instead of talking to the helper.
    private var exec: ExecSession?

    init(remote: WireConnection, gateway: SessionGateway) {
        self.remote = remote
        self.gateway = gateway
    }

    func start(queue: DispatchQueue, authTimeout: TimeInterval) {
        remote.onMessage = { [weak self] message in self?.fromRemote(message, queue: queue) }
        remote.onClose = { [weak self] in self?.close() }
        remote.startReading(queue: queue)
        queue.asyncAfter(deadline: .now() + authTimeout) { [weak self] in
            guard let self, self.local == nil else { return }
            self.close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        exec?.terminate()
        remote.close()
        local?.close()
        gateway?.ended(self)
    }

    private func fromRemote(_ message: WireMessage, queue: DispatchQueue) {
        guard let local else { return authenticate(message, queue: queue) }
        if let exec {
            if case .input(let bytes) = message { exec.write(bytes) }
            return
        }
        switch message {
        case .exec(let argv):
            do {
                exec = try gateway?.exec(argv, for: remote)
                // A command's connection doesn't use the helper.
                local.onClose = nil
                local.close()
            } catch {
                try? remote.send(.error("exec failed: \(error)"))
                remote.closeAfterSending()
            }
        // The helper's lifetime isn't a remote client's to end.
        case .auth, .shutdownIfIdle: return
        case .spawn(let request): send(.spawn(gateway?.localize(request) ?? request), to: local)
        default: send(message, to: local)
        }
    }

    private func authenticate(_ message: WireMessage, queue: DispatchQueue) {
        guard case .auth(let token) = message, gateway?.accepts(token) == true,
              let helper = try? gateway?.openHelper() else {
            try? remote.send(.error("unauthorized"))
            remote.closeAfterSending()
            return
        }
        local = helper
        helper.onMessage = { [weak self] message in self?.fromHelper(message) }
        helper.onClose = { [weak self] in self?.close() }
        helper.startReading(queue: queue)
    }

    private func fromHelper(_ message: WireMessage) {
        guard let local else { return }
        // The pty master can't cross the network, and holding it here would keep it open.
        while let fd = local.takeFD() { Foundation.close(fd) }
        send(message, to: remote)
        guard remote.backlogBytes > SessionGateway.pauseAbove else { return }
        local.pauseReading()
        remote.whenBacklog(atMost: SessionGateway.resumeAt) { [weak local] in local?.resumeReading() }
    }

    private func send(_ message: WireMessage, to connection: WireConnection) {
        if (try? connection.send(message)) == nil { close() }
    }
}
