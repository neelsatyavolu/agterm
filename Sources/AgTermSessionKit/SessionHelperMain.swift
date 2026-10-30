import Foundation

/// The sessions helper's entry point: `agterm --sessions-helper --socket <path> --build <id>`.
/// On a cloud machine `--listen <host:port>` also starts the gateway, with the token in
/// `AGTERM_GATEWAY_TOKEN` (never on the command line, which `ps` shows), and the helper no
/// longer stops when idle; `--idle-stop <seconds>` then exits once `SessionServer.quietFor` passes
/// that, which stops a Fly machine (its proxy starts it again for the next connection).
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
        let gateway = value(of: "--listen", in: arguments).map(makeGateway)
        daemonize()
        do {
            let server = SessionServer(socketPath: socketPath, build: value(of: "--build", in: arguments) ?? "unknown")
            if let gateway {
                server.idleExitAfter = nil
                server.statePath = value(of: "--state", in: arguments)
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

    /// Checks every 30 s; ending its shells first, so they hang up like on any shutdown.
    private static func stopWhenQuiet(_ server: SessionServer, after limit: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler {
            guard let quiet = server.quietFor, quiet >= limit else { return }
            server.stop()
            exit(0)
        }
        timer.resume()
        idleTimer = timer
    }

    nonisolated(unsafe) private static var idleTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Fly stops a machine with SIGINT (SIGTERM elsewhere): keep the sessions, then exit.
    private static func stopOnSignals(_ server: SessionServer) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
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
