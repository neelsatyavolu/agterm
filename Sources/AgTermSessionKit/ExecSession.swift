import AgTermCore
import Foundation

/// A command the gateway runs for a client with plain pipes (`exec`): rsync's server end when
/// tabs move to or from the cloud. Input from the client is written on its own queue and, past
/// a limit, the client isn't read until the command catches up; output isn't read while the
/// client has a backlog. `exited` follows the last output. Used only on the gateway's queue.
final class ExecSession {
    private static let readSize = 64 * 1024
    private static let pauseAbove = 4 * 1024 * 1024
    private static let resumeAt = 1 * 1024 * 1024
    private static let inputPauseAbove = 1024 * 1024
    private static let inputResumeAt = 64 * 1024

    private let pid: pid_t
    private let client: WireConnection
    private let queue: DispatchQueue
    private var stdin: PtyWriter?
    private var readers: [DispatchSourceRead] = []
    private var suspended = false
    private var openOutputs = 2
    private var status: Int32?
    private var exitWatcher: ExitWatcher?
    private var finished = false
    /// Holds the session until its command is reaped and its pipes are closed, whatever happens
    /// to the client: the bridge lets go as soon as the client does.
    private var keepAlive: ExecSession?

    /// `env` is `KEY=VALUE` entries. Throws if the command can't be started.
    init(argv: [String], env: [String], client: WireConnection, queue: DispatchQueue) throws {
        guard let path = argv.first, path.hasPrefix("/") else { throw POSIXError(.ENOENT) }
        self.client = client
        self.queue = queue
        var pipes: [[Int32]] = []
        for _ in 0..<3 {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                pipes.flatMap { $0 }.forEach { _ = Foundation.close($0) }
                throw POSIXError.current
            }
            pipes.append(fds)
        }
        // Ours: stdin's write end, stdout's and stderr's read ends; the child's are dup'ed over 0, 1, 2.
        // All are close-on-exec, so the command (and anything it leaves running) holds only 0, 1, 2.
        let ours = [pipes[0][1], pipes[1][0], pipes[2][0]]
        let theirs = [pipes[0][0], pipes[1][1], pipes[2][1]]
        (ours + theirs).forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        do {
            pid = try Self.spawn(path: path, argv: argv, env: env, stdio: theirs)
        } catch {
            (ours + theirs).forEach { _ = Foundation.close($0) }
            throw error
        }
        theirs.forEach { _ = Foundation.close($0) }
        stdin = PtyWriter(fd: ours[0])
        readers = [read(ours[1], index: 0, as: WireMessage.output), read(ours[2], index: 1, as: WireMessage.stderr)]
        exitWatcher = ExitWatcher(pid: pid, queue: queue) { [weak self] in self?.reap() }
        keepAlive = self
    }

    /// Input for the command; empty closes its stdin.
    func write(_ bytes: Data) {
        guard let stdin else { return }
        guard !bytes.isEmpty else {
            stdin.close()
            self.stdin = nil
            return
        }
        stdin.write([UInt8](bytes)[...])
        guard stdin.pendingBytes > Self.inputPauseAbove else { return }
        client.pauseReading()
        stdin.whenPending(atMost: Self.inputResumeAt, on: queue) { [weak client] in client?.resumeReading() }
    }

    /// The client went away: the command is killed and reaped.
    func terminate() {
        if status == nil { kill(pid, SIGKILL) }
        // A suspended source must be resumed before it is cancelled or released.
        if suspended {
            suspended = false
            readers.forEach { $0.resume() }
        }
        readers.forEach { $0.cancel() }
        openOutputs = 0
        finishIfDone()
    }

    // MARK: Private

    /// `index` is the reader's place in `readers`.
    private func read(_ fd: Int32, index: Int, as wrap: @escaping (Data) -> WireMessage) -> DispatchSourceRead {
        UnixSocket.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readSize, alignment: 8)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let count = Foundation.read(fd, buffer, Self.readSize)
            if count > 0 {
                self.send(wrap(Data(bytes: buffer, count: count)))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                guard !self.readers[index].isCancelled else { return }
                self.readers[index].cancel()
                self.openOutputs -= 1
                self.finishIfDone()
            }
        }
        source.setCancelHandler {
            buffer.deallocate()
            Foundation.close(fd)
        }
        source.resume()
        return source
    }

    private func send(_ message: WireMessage) {
        guard (try? client.send(message)) != nil else { return terminate() }
        guard !suspended, client.backlogBytes > Self.pauseAbove else { return }
        suspended = true
        readers.forEach { $0.suspend() }
        client.whenBacklog(atMost: Self.resumeAt) { [weak self] in
            guard let self, self.suspended else { return }
            self.suspended = false
            self.readers.forEach { $0.resume() }
        }
    }

    private func reap() {
        var raw: Int32 = 0
        let result = waitpid(pid, &raw, 0)
        status = result == pid ? HostedSession.exitCode(raw) : -1
        exitWatcher?.cancel()
        exitWatcher = nil
        finishIfDone()
    }

    /// Once the command has exited and both outputs are drained (a background child holding
    /// them open keeps the session going until it lets go).
    private func finishIfDone() {
        guard !finished, let status, openOutputs == 0 else { return }
        finished = true
        stdin?.close()
        stdin = nil
        try? client.send(.exited(id: "exec", status: status))
        client.closeAfterSending()
        keepAlive = nil
    }

    private static func spawn(path: String, argv: [String], env: [String], stdio: [Int32]) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, fd) in stdio.enumerated() { posix_spawn_file_actions_adddup2(&actions, fd, Int32(target)) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The helper ignores SIGHUP and SIGPIPE; the command gets the defaults back.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGHUP)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgv + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, cArgv, cEnv)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}
