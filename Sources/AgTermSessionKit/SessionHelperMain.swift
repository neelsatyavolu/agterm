import AgTermCore
import Foundation

/// The sessions helper's entry point: `agterm --sessions-helper --socket <path> --build <id>`.
/// On a cloud machine `--listen <host:port>` also starts the gateway, with the token in
/// `AGTERM_GATEWAY_TOKEN` (never on the command line, which `ps` shows), and the helper no
/// longer stops when idle; `--idle-stop <seconds>` then exits once `SessionServer.quietFor` passes
/// that, which stops a Fly machine (its proxy starts it again for the next connection).
/// On a Mac that lets paired Macs run tasks (Settings → Macs), `--mac-listen <port>` with
/// `--mac-name <name>` serves them instead, over `MacLink`, with the secret in `AGTERM_MAC_SECRET`.
/// The helper owns every tab's shell so it survives the app quitting (see SessionServer). It is
/// the app's own executable, so macOS privacy checks for its shells (Full Disk Access and the
/// like) see agterm's code identity even after the app quits.
public enum SessionHelperMain {
    public static let flag = "--sessions-helper"

    public static func run(arguments: [String]) -> Never {
        guard let socketPath = value(of: "--socket", in: arguments) else {
            FileHandle.standardError.write(Data("usage: agterm \(flag) --socket <path> --build <id>\n".utf8))
            exit(2)
        }
        #if canImport(Network)
        if let port = value(of: "--mac-listen", in: arguments) { runMacWorker(socketPath: socketPath, port: port, arguments: arguments) }
        #endif
        let gateway = value(of: "--listen", in: arguments).map(makeGateway)
        daemonize()
        do {
            let server = SessionServer(socketPath: socketPath, build: value(of: "--build", in: arguments) ?? "unknown")
            if let gateway {
                server.idleExitAfter = nil
                server.statePath = value(of: "--state", in: arguments)
                server.phoneHandoffPath = NSHomeDirectory() + "/" + CloudPhoneHandoff.path
                try server.start()
                // Kept here: nothing else holds it, and dispatchMain never returns.
                let running = gateway(socketPath)
                try running.start()
                if let limit = value(of: "--idle-stop", in: arguments).flatMap(TimeInterval.init) { stopWhenQuiet(server, after: limit) }
                stopOnSignals(server)
                withExtendedLifetime(running) { dispatchMain() }
            }
            try server.run()
        } catch {
            FileHandle.standardError.write(Data("agterm sessions helper: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// Exits with usage if the endpoint or token is missing or the token is short.
    private static func makeGateway(_ endpoint: String) -> (String) -> SessionGateway {
        let token = ProcessInfo.processInfo.environment[tokenVariable] ?? ""
        guard let (host, port) = TCPSocket.parse(endpoint), token.utf8.count >= minimumTokenLength else {
            FileHandle.standardError.write(Data("usage: \(flag) --listen <host:port> with \(tokenVariable) set (at least \(minimumTokenLength) characters)\n".utf8))
            exit(2)
        }
        return { SessionGateway(socketPath: $0, host: host, port: port, token: token) }
    }

    #if canImport(Network)
    /// Serves paired Macs until it is told to stop (Settings → Macs turned off). Their tasks run
    /// as `exec`; the sessions server is there for the gateway's handshake.
    private static func runMacWorker(socketPath: String, port: String, arguments: [String]) -> Never {
        let secret = ProcessInfo.processInfo.environment[MacLink.secretVariable] ?? ""
        guard let port = UInt16(port), secret.utf8.count >= minimumTokenLength else {
            FileHandle.standardError.write(Data("usage: \(flag) --mac-listen <port> --mac-name <name> with \(MacLink.secretVariable) set\n".utf8))
            exit(2)
        }
        daemonize()
        do {
            let server = SessionServer(socketPath: socketPath, build: value(of: "--build", in: arguments) ?? "unknown")
            server.idleExitAfter = nil
            try server.start()
            let gateway = SessionGateway(socketPath: socketPath, host: "127.0.0.1", port: 0, token: MacLink.token(secret: secret))
            let listener = try MacListener(port: port, secret: secret, serviceName: value(of: "--mac-name", in: arguments)) { gateway.serve($0) }
            try listener.start()
            stopOnSignals(server) {
                // Paired Macs' commands are the gateway's, in their own process groups: they are
                // told to stop with the link, and killed 3 s later (`ExecSession.terminate`).
                listener.stop()
                gateway.stop()
                usleep(3_500_000)
            }
            withExtendedLifetime((gateway, listener)) { dispatchMain() }
        } catch {
            FileHandle.standardError.write(Data("agterm sessions helper: \(error)\n".utf8))
            exit(1)
        }
    }
    #endif

    /// Checks every 30 s; ending its shells first, so they hang up like on any shutdown.
    private static func stopWhenQuiet(_ server: SessionServer, after limit: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler {
            guard let quiet = server.quietFor, quiet >= limit, !setupRunning(in: NSHomeDirectory() + "/" + CloudSetup.stateFolder) else { return }
            server.stop()
            exit(0)
        }
        timer.resume()
        idleTimer = timer
    }

    /// Whether a dependency install after a move (`CloudSetup`) is still going: it runs outside
    /// any tab, holding its folder's lock. Taking the lock for a moment to test it is safe, as a
    /// run waits a few seconds for it.
    static func setupRunning(in folder: String) -> Bool {
        let locks = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(CloudSetup.setupLockSuffix) }
        return locks.contains { name in
            let fd = open(folder + "/" + name, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return flock(fd, LOCK_EX | LOCK_NB) != 0
        }
    }

    nonisolated(unsafe) private static var idleTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Fly stops a machine with SIGINT (SIGTERM elsewhere): keep the sessions, then exit.
    private static func stopOnSignals(_ server: SessionServer, first: @escaping () -> Void = {}) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                first()
                server.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    public static let tokenVariable = "AGTERM_GATEWAY_TOKEN"
    private static let minimumTokenLength = 32

    private static func value(of name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// A daemon: own session, no terminal, nothing held open in the app's working directory.
    private static func daemonize() {
        setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        chdir("/")
        let devNull = open("/dev/null", O_RDWR)
        guard devNull >= 0 else { return }
        dup2(devNull, STDIN_FILENO)
        dup2(devNull, STDOUT_FILENO)
        #if !DEBUG
        dup2(devNull, STDERR_FILENO)
        #endif
        if devNull > STDERR_FILENO { close(devNull) }
    }
}
