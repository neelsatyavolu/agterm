import AgTermCore
import AgTermSessionKit
import Foundation

/// Finds, starts and talks to `agterm-sessions`, the helper that owns tab shells and keeps them
/// running while the app is quit. The first call connects (launching the helper if nothing
/// answers) and the client is kept. Without one (the helper binary is missing, doesn't answer
/// within 2 s, or speaks another protocol version) tabs run in-process; that, or a helper that
/// has since died, is tried again at most every 30 s.
enum SessionHelper {
    private static let startTimeout: TimeInterval = 2
    private static let retryInterval: TimeInterval = 30
    /// Main queue only.
    private static var client: Client?
    private static var lastStart: Date?
    private static var reapers: [pid_t: DispatchSourceProcess] = [:]

    static func shared() -> Client? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let client, client.isAlive { return client }
        if let lastStart, Date().timeIntervalSince(lastStart) < retryInterval { return nil }
        lastStart = Date()
        client = start()
        return client
    }

    /// The helper's process, if this app is using one (the self-test counts its shells).
    static var runningPID: pid_t? {
        client?.pid
    }

    /// Next to the app's executable: `Contents/MacOS` in the bundle, `.build/debug` in development.
    private static var binary: String? {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agterm-sessions"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    /// Derived from the state folder, so `AGTERM_STATE_DIR` and debug builds get their own helper.
    static var socketPath: String {
        SessionPaths.socket(stateDir: WorkspaceStore.fileURL.deletingLastPathComponent().path)
    }

    static var buildID: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    private static func start() -> Client? {
        guard let binary else { return nil }
        let socket = socketPath
        let build = buildID
        var launched = false
        var replaced = false
        var deadline = Date().addingTimeInterval(startTimeout)
        while true {
            do {
                let (control, serverBuild) = try HelperHandshake.connect(socket: socket, build: build,
                                                                         timeout: max(0.1, deadline.timeIntervalSinceNow))
                let client = Client(control: control, socket: socket, build: build)
                // A helper from another build with no shells to keep makes way for ours, once.
                if serverBuild != build, !replaced, client.list()?.isEmpty == true {
                    replaced = true
                    client.shutDown()
                    waitForRemoval(socket, until: Date().addingTimeInterval(startTimeout))
                    launched = launch(binary, socket: socket, build: build)
                    deadline = Date().addingTimeInterval(startTimeout)
                    continue
                }
                return client
            } catch let mismatch as HelperHandshake.VersionMismatch {
                NSLog("agterm: sessions helper speaks protocol %ld, not %ld; tabs run in-process", mismatch.server, SessionWire.protocolVersion)
                return nil
            } catch {
                if !launched {
                    launched = true
                    guard launch(binary, socket: socket, build: build) else { return nil }
                }
                guard Date() < deadline else {
                    NSLog("agterm: sessions helper didn't answer (%@); tabs run in-process", String(describing: error))
                    return nil
                }
                usleep(20_000)
            }
        }
    }

    private static func waitForRemoval(_ path: String, until deadline: Date) {
        while access(path, F_OK) == 0 && Date() < deadline { usleep(20_000) }
    }

    /// Starts the helper in its own session with no terminal and none of our descriptors, so it
    /// outlives the app. It exits at once if another helper already serves the socket.
    private static func launch(_ binary: String, socket: String, build: String) -> Bool {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
        let argv = [binary, "--socket", socket, "--build", build].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary, &actions, &attributes, argv, environ)
        guard result == 0 else {
            NSLog("agterm: couldn't start the sessions helper: %s", strerror(result))
            return false
        }
        reapWhenDone(pid)
        return true
    }

    /// The helper is our child until it exits (it may exit at once, or idle out later).
    private static func reapWhenDone(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { reap(pid) }
        reapers[pid] = source
        source.resume()
        // It may have exited before the source was armed.
        DispatchQueue.main.async { reap(pid) }
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        reapers.removeValue(forKey: pid)?.cancel()
    }

    /// A greeted connection to the helper, kept open for `list()`; each tab gets its own.
    final class Client {
        private static let replyTimeout: TimeInterval = 2

        let socket: String
        let build: String
        let pid: pid_t?
        private let control: WireConnection
        private let lock = NSLock()

        fileprivate init(control: WireConnection, socket: String, build: String) {
            self.control = control
            pid = control.peerPID
            self.socket = socket
            self.build = build
        }

        /// The helper's shells, oldest first; nil if it doesn't answer (unlike an empty list,
        /// that says nothing about which shells it has).
        func list() -> [SessionInfo]? {
            lock.lock()
            defer { lock.unlock() }
            guard (try? control.send(.list)) != nil,
                  case .sessions(let infos)? = try? control.receive(timeout: Self.replyTimeout) else { return nil }
            return infos
        }

        func spawn(_ request: SpawnRequest) throws -> HelperLink {
            try link(.spawn(request), showReplay: false)
        }

        func attach(id: String) throws -> HelperLink {
            try link(.attach(id: id), showReplay: true)
        }

        /// A new connection that sent `request` (spawn or attach) and got `attached` back, with
        /// the pty master that came with it.
        func open(_ request: WireMessage) throws -> (WireConnection, SessionInfo, Int32) {
            let (connection, _) = try HelperHandshake.connect(socket: socket, build: build, timeout: Self.replyTimeout)
            do {
                try connection.send(request)
                switch try connection.receive(timeout: Self.replyTimeout) {
                case .attached(let info):
                    guard let fd = connection.takeFD() else { throw WireError.unexpectedReply }
                    return (connection, info, fd)
                case .error(let text): throw WireError.remote(text)
                default: throw WireError.unexpectedReply
                }
            } catch {
                connection.close()
                throw error
            }
        }

        /// False once the helper process is gone (it crashed or was killed).
        var isAlive: Bool {
            pid.map { kill($0, 0) == 0 } ?? true
        }

        private func link(_ request: WireMessage, showReplay: Bool) throws -> HelperLink {
            let (connection, info, fd) = try open(request)
            return HelperLink(client: self, connection: connection, info: info, ptyFd: fd, showReplay: showReplay)
        }

        fileprivate func shutDown() {
            try? control.send(.shutdownIfIdle)
            control.close()
        }
    }
}
