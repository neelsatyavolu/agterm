import AgTermCore
import Foundation

public enum SessionServerError: Error, Equatable {
    /// Another helper is already serving this socket.
    case alreadyRunning
    /// Something other than a socket sits at the socket path.
    case pathInUse
}

/// The sessions helper (`agterm --sessions-helper`): owns every tab's shell and serves the app over a Unix socket,
/// so shells outlive app updates, quits and crashes. All state lives on one serial queue.
public final class SessionServer {
    /// Where a cloud machine keeps its sessions across a stop (`SessionKeeper`); nil keeps nothing.
    /// Set before `start()`.
    public var statePath: String?
    /// With no sessions and no clients for this long, the server stops; nil never stops (a
    /// cloud machine's helper, which the gateway reaches).
    public var idleExitAfter: TimeInterval? = 10
    /// A cloud machine's `CloudPhoneHandoff`: with it, the phone reaches these sessions while
    /// the Mac is off (`CloudPhone`). Set before `start()`.
    public var phoneHandoffPath: String?
    /// How long the Mac must be gone before the phone is served from here.
    public var phoneMacGoneAfter = CloudPhoneRule.macGoneAfter

    private let socketPath: String
    private let build: String
    private let queue = DispatchQueue(label: "agterm.sessions")
    private let finished = DispatchSemaphore(value: 0)
    private var listener: DispatchSourceRead?
    private var clients: [ObjectIdentifier: WireConnection] = [:]
    /// Clients that have sent a matching `hello`.
    private var greeted: Set<ObjectIdentifier> = []
    private var sessions: [String: HostedSession] = [:]
    private var stopped = false
    private var idleToken = 0
    /// The last time a shell wrote something or a client came or went.
    private var lastActivity = Date()
    /// When the last client left (or the server started): when the Mac was last here.
    private var lastClientLeft = Date()
    private var phone: CloudPhone?

    public init(socketPath: String, build: String) {
        self.socketPath = socketPath
        self.build = build
    }

    /// Serves until idle or `stop()`. Returns at once if another server already has the socket.
    public func run() throws {
        do {
            try start()
        } catch SessionServerError.alreadyRunning {
            return
        }
        finished.wait()
    }

    /// Binds the socket and starts serving on the server's queue without blocking.
    public func start() throws {
        try queue.sync {
            try listen()
            if let statePath { SessionKeeper.take(from: statePath).forEach(restore) }
            if let phoneHandoffPath { startPhone(handoff: phoneHandoffPath) }
        }
        queue.async { self.noteActivity() }
    }

    /// Kills every session, drops every client and removes the socket. Not for use on the server's queue.
    public func stop() {
        queue.sync { shutdown() }
    }

    // MARK: Socket

    private func listen() throws {
        try SessionPaths.prepareDirectory((socketPath as NSString).deletingLastPathComponent)
        let fd: Int32
        do {
            fd = try UnixSocket.listen(path: socketPath)
        } catch let error as POSIXError where error.code == .EADDRINUSE {
            // Live server, or a stale socket left by one that died.
            if let probe = try? UnixSocket.connect(path: socketPath) {
                close(probe)
                throw SessionServerError.alreadyRunning
            }
            var info = stat()
            guard lstat(socketPath, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { throw SessionServerError.pathInUse }
            unlink(socketPath)
            fd = try UnixSocket.listen(path: socketPath)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    private func acceptAll(_ listenFd: Int32) {
        while true {
            let fd = accept(listenFd, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.configure(fd)
            guard (try? UnixSocket.requirePeer(fd, uid: getuid())) != nil else {
                close(fd)
                continue
            }
            let connection = WireConnection(fd: fd)
            let key = ObjectIdentifier(connection)
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection else { return }
                self.handle(message, from: connection)
            }
            connection.onClose = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.dropClient(connection, key: key)
            }
            clients[key] = connection
            connection.startReading(queue: queue)
            noteActivity()
        }
    }

    // MARK: Messages

    private func handle(_ message: WireMessage, from client: WireConnection) {
        let key = ObjectIdentifier(client)
        guard greeted.contains(key) else { return greet(message, from: client, key: key) }
        switch message {
        case .list:
            reply(client, .sessions(sessions.values.map(\.info).sorted { $0.startedAt < $1.startedAt }))
        case .spawn(let request):
            spawn(request, for: client)
        case .attach(let id):
            guard let session = sessions[id] else { return reply(client, .error("no such session")) }
            detachEverywhere(client)
            session.attach(client)
        case .kill(let id, let signal):
            guard let session = sessions[id] else { return reply(client, .error("no such session")) }
            guard (1..<32).contains(signal) else { return reply(client, .error("bad signal")) }
            session.signal(signal)
        case .input(let bytes):
            sessions.values.first { $0.isAttached(client) }?.write(bytes, from: client)
        case .signalForeground(let signal):
            guard (1..<32).contains(signal) else { return reply(client, .error("bad signal")) }
            sessions.values.first { $0.isAttached(client) }?.signalForeground(signal)
        case .inspect:
            guard let session = sessions.values.first(where: { $0.isAttached(client) }) else { return reply(client, .error("not attached")) }
            reply(client, .foreground(session.foreground()))
        case .resize(let size):
            sessions.values.first { $0.isAttached(client) }?.resize(size)
        case .shutdownIfIdle:
            if sessions.isEmpty { shutdown() }
        default:
            reply(client, .error("unexpected message"))
        }
    }

    /// Every connection starts with `hello`; the server answers with its own, then refuses a
    /// client speaking a different protocol version.
    private func greet(_ message: WireMessage, from client: WireConnection, key: ObjectIdentifier) {
        guard case .hello(let version, _) = message else {
            reply(client, .error("expected hello"))
            return client.closeAfterSending()
        }
        reply(client, .hello(version: SessionWire.protocolVersion, build: build))
        guard version == SessionWire.protocolVersion else {
            reply(client, .error("protocol version mismatch"))
            return client.closeAfterSending()
        }
        greeted.insert(key)
    }

    private func spawn(_ request: SpawnRequest, for client: WireConnection) {
        let session: HostedSession
        do {
            session = try HostedSession(request: request, queue: queue)
        } catch {
            return reply(client, .error("spawn failed: \(error)"))
        }
        register(session)
        detachEverywhere(client)
        session.attach(client)
        session.start()
        noteActivity()
    }

    /// A session kept across a machine stop, back under its old id with its screen and agent.
    private func restore(_ kept: KeptSession) {
        guard sessions[kept.id] == nil, let session = try? HostedSession(request: kept.request, queue: queue, id: kept.id) else { return }
        session.restore(screen: kept.screen, resume: kept.resume)
        register(session)
        session.start()
    }

    private func register(_ session: HostedSession) {
        session.onExit = { [weak self] session in
            self?.sessions[session.id] = nil
            self?.noteActivity()
        }
        session.onOutput = { [weak self] in self?.lastActivity = Date() }
        sessions[session.id] = session
    }

    private func reply(_ client: WireConnection, _ message: WireMessage) {
        try? client.send(message)
    }

    private func detachEverywhere(_ client: WireConnection) {
        sessions.values.forEach { $0.detach(client) }
    }

    private func dropClient(_ client: WireConnection, key: ObjectIdentifier) {
        clients[key] = nil
        if clients.isEmpty { lastClientLeft = Date() }
        greeted.remove(key)
        detachEverywhere(client)
        noteActivity()
    }

    // MARK: Lifetime

    /// How long it has been quiet: no client connected and no shell output. Nil while a client
    /// is connected. A working agent keeps writing (its spinner, its timer), so a cloud machine
    /// stops only once its agents are done and nobody is looking.
    public var quietFor: TimeInterval? {
        queue.sync { clients.isEmpty ? Date().timeIntervalSince(lastActivity) : nil }
    }

    /// Called on every change; schedules the idle exit when nothing is left.
    private func noteActivity() {
        lastActivity = Date()
        idleToken &+= 1
        guard !stopped, sessions.isEmpty, clients.isEmpty, let idleExitAfter else { return }
        let token = idleToken
        queue.asyncAfter(deadline: .now() + idleExitAfter) { [weak self] in
            guard let self, self.idleToken == token, self.sessions.isEmpty, self.clients.isEmpty else { return }
            self.shutdown()
        }
    }

    private func startPhone(handoff path: String) {
        let host = CloudPhone.Host(
            sessions: { [weak self] in self.map { Array($0.sessions.values) } ?? [] },
            macConnected: { [weak self] in self?.clients.isEmpty == false },
            macLastSeen: { [weak self] in self?.lastClientLeft ?? Date() },
            touch: { [weak self] in self?.lastActivity = Date() })
        phone = CloudPhone(queue: queue, host: host, handoffPath: path, build: build, macGoneAfter: phoneMacGoneAfter)
        phone?.start()
    }

    private func shutdown() {
        guard !stopped else { return }
        stopped = true
        phone?.stop()
        phone = nil
        listener?.cancel()
        listener = nil
        unlink(socketPath)
        if let statePath { SessionKeeper.save(sessions.values.sorted { $0.startedAt < $1.startedAt }.map { $0.kept() }, to: statePath) }
        sessions.values.forEach { $0.terminate() }
        sessions = [:]
        clients.values.forEach { $0.close() }
        clients = [:]
        greeted = []
        finished.signal()
    }
}
