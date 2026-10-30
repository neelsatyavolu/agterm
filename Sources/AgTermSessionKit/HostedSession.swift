import AgTermCore
import Foundation
import SwiftTerm

/// One shell the helper owns: its pty, a headless terminal that keeps the screen while no
/// client is attached, and the attached client, if any. Used only on the server's queue.
final class HostedSession {
    static let scrollback = 10_000
    private static let readSize = 64 * 1024
    /// How long after a `kill` before the shell gets SIGKILL.
    private static let killGrace: TimeInterval = 2
    /// Backpressure: the pty isn't read while the attached client has more than `pauseAbove`
    /// unsent, until it is down to `resumeAt`, so a slow client blocks the shell's writes
    /// rather than growing the helper's memory (or getting dropped).
    private static let pauseAbove = 4 * 1024 * 1024
    private static let resumeAt = 1 * 1024 * 1024
    /// The same for input from a client without the pty: past this much the program hasn't
    /// taken, the client isn't read until it is down to `inputResumeAt`.
    private static let inputPauseAbove = 1024 * 1024
    private static let inputResumeAt = 64 * 1024
    #if canImport(Darwin)
    private static let getWindowSize = TIOCGWINSZ
    private static let setWindowSize = TIOCSWINSZ
    #else
    private static let getWindowSize = UInt(TIOCGWINSZ)
    private static let setWindowSize = UInt(TIOCSWINSZ)
    #endif

    let id = UUID().uuidString
    let pid: pid_t
    let cwd: String
    let startedAt = Date()
    /// Called once the shell has exited and been reaped.
    var onExit: ((HostedSession) -> Void)?
    /// Called whenever the shell writes something.
    var onOutput: (() -> Void)?

    private let masterFd: Int32
    private let queue: DispatchQueue
    private let terminal: Terminal
    private let terminalDelegate = HeadlessDelegate()
    private var readSource: DispatchSourceRead?
    /// The reader is suspended once every slave has closed, until the shell is reaped.
    private var readerSuspended = false
    private var exitWatcher: ExitWatcher?
    private var client: WireConnection?
    /// The client whose backlog has the reader suspended.
    private var throttledBy: WireConnection?
    private var exited = false
    /// Input from a client without the pty (`input`); made on first use.
    private var writer: PtyWriter?
    private let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: readSize, alignment: 8)

    var info: SessionInfo { SessionInfo(id: id, pid: pid, cwd: cwd, startedAt: startedAt, attached: client != nil) }

    init(request: SpawnRequest, queue: DispatchQueue) throws {
        (pid, masterFd) = try PtySpawn.fork(request)
        cwd = request.cwd
        self.queue = queue
        terminal = Self.makeTerminal(cols: Int(request.cols), rows: Int(request.rows), delegate: terminalDelegate)
    }

    /// The headless terminal that keeps a session's screen.
    static func makeTerminal(cols: Int, rows: Int, delegate: TerminalDelegate) -> Terminal {
        let options = TerminalOptions(cols: max(1, cols), rows: max(1, rows), scrollback: scrollback)
        let terminal = Terminal(delegate: delegate, options: options)
        // The safety timeout would run on the main queue, which the helper never drains (its
        // main thread waits in `SessionServer.run`), so each `ESC[?2026h` would leak. Nothing
        // here draws, and the attached app's own terminal keeps its timeout.
        terminal.synchronizedOutputTimeoutQueue = nil
        return terminal
    }

    deinit {
        readBuffer.deallocate()
    }

    /// Starts reading the pty and watching for the shell's exit.
    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readPty() }
        // The master stays open until the session ends, so its number is never reused while
        // `attach` or `signal` might still use it.
        reader.setCancelHandler { [masterFd] in Foundation.close(masterFd) }
        readSource = reader
        reader.resume()

        exitWatcher = ExitWatcher(pid: pid, queue: queue) { [weak self] in self?.reap(blocking: true) }
        // The shell may have died before the watcher was registered.
        queue.async { [weak self] in self?.reap(blocking: false) }
    }

    /// Makes `connection` this session's client, and sends it `attached` (carrying the pty
    /// master) and the screen replay. A previous client is told it was superseded, then closed.
    func attach(_ connection: WireConnection) {
        if let old = client, old !== connection {
            try? old.send(.error(SessionWire.superseded))
            old.closeAfterSending()
        }
        unthrottle()
        client = connection
        syncSize()
        try? connection.send(.attached(info), fd: masterFd)
        try? connection.send(.replay(ScreenReplay.bytes(terminal)))
    }

    func isAttached(_ connection: WireConnection) -> Bool {
        client === connection
    }

    /// Input from `connection`, a client that has no pty descriptor. Written on the writer's own
    /// queue, so a shell that isn't reading its input never blocks the server; past a limit the
    /// client isn't read until the program catches up, so the backlog can't grow without end.
    func write(_ bytes: Data, from connection: WireConnection) {
        guard !exited, !bytes.isEmpty else { return }
        if writer == nil {
            let fd = fcntl(masterFd, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else { return }
            writer = PtyWriter(fd: fd)
        }
        guard let writer else { return }
        writer.write([UInt8](bytes)[...])
        guard writer.pendingBytes > Self.inputPauseAbove else { return }
        connection.pauseReading()
        writer.whenPending(atMost: Self.inputResumeAt, on: queue) { [weak connection] in connection?.resumeReading() }
    }

    /// A new size from a client that has no pty descriptor; the kernel tells the foreground job.
    func resize(_ size: WindowSize) {
        guard !exited, size.cols > 0, size.rows > 0 else { return }
        var window = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: size.width, ws_ypixel: size.height)
        guard ioctl(masterFd, Self.setWindowSize, &window) == 0 else { return }
        syncSize()
    }

    /// What the pty has in the foreground, looked up on this machine.
    func foreground() -> ForegroundInfo {
        let group = ProcInfo.foregroundPid(ptyFd: masterFd) ?? pid
        let isShell = group == pid
        let argv = ProcInfo.arguments(pid: group)
        let name = ProcInfo.name(pid: group) ?? argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        var info = ForegroundInfo(pid: group, isShell: isShell, name: name, argv: argv,
                                  cwd: ProcInfo.cwd(pid: group) ?? ProcInfo.cwd(pid: pid))
        guard !isShell else { return info }
        if let claude = ProcInfo.claudeSession(pid: group) {
            info.claudeSessionID = claude.id
            info.claudeBusy = claude.busy
        }
        guard argv.contains(where: { ($0 as NSString).lastPathComponent.hasPrefix("codex") }) else { return info }
        info.codexSessionID = ProcInfo.openFiles(group: group) { $0.contains("/sessions/") && $0.contains("rollout-") && $0.hasSuffix(".jsonl") }
            .lazy.compactMap(Self.firstLine).compactMap(AgentResume.codexSessionID(rolloutHeader:)).first
        return info
    }

    private static func firstLine(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    func detach(_ connection: WireConnection) {
        if client === connection { client = nil }
        if throttledBy === connection { unthrottle() }
    }

    /// Sends `signal` to the shell, and SIGHUP to the foreground job too (as Terminal.app does
    /// on close); SIGKILL follows if the shell is still there after the grace period.
    func signal(_ signal: Int32) {
        guard !exited else { return }
        let foreground = tcgetpgrp(masterFd)
        kill(pid, signal)
        if signal == SIGHUP, foreground > 0, foreground != pid { killpg(foreground, SIGHUP) }
        queue.asyncAfter(deadline: .now() + Self.killGrace) { [weak self] in
            guard let self, !self.exited else { return }
            kill(self.pid, SIGKILL)
        }
    }

    /// Kills the shell and its jobs now and reaps it, without telling the client.
    func terminate() {
        guard !exited else { return }
        let foreground = tcgetpgrp(masterFd)
        if foreground > 0, foreground != pid { killpg(foreground, SIGKILL) }
        killpg(pid, SIGKILL)
        kill(pid, SIGKILL)
        // A dying session leader waits for its pty output to drain, so keep reading (and
        // discarding) while waiting for it; give up after a while rather than hang.
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(Self.killGrace)
        while waitpid(pid, &status, WNOHANG) == 0 && Date() < deadline {
            var poller = pollfd(fd: masterFd, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, 10) > 0 && read(masterFd, readBuffer, Self.readSize) <= 0 { usleep(10_000) }
        }
        client = nil
        finish(status: 128 + SIGKILL)
    }

    // MARK: Private

    /// Reads once if that can't block (the client holds the same pty open). Returns whether it got bytes.
    @discardableResult
    private func readPty() -> Bool {
        guard !readerSuspended else { return false }
        var poller = pollfd(fd: masterFd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 0) > 0 else { return false }
        let count = read(masterFd, readBuffer, Self.readSize)
        if count > 0 {
            received(Data(bytes: readBuffer, count: count))
            return true
        }
        if count == 0 || (errno != EINTR && errno != EAGAIN) {
            // Every slave is closed; the exit watcher finishes the session.
            readSource?.suspend()
            readerSuspended = true
        }
        return false
    }

    private func received(_ bytes: Data) {
        onOutput?()
        syncSize()
        terminal.feed(buffer: [UInt8](bytes)[...])
        guard let client else { return }
        try? client.send(.output(bytes))
        if throttledBy == nil, client.backlogBytes > Self.pauseAbove { throttle(client) }
    }

    private func throttle(_ connection: WireConnection) {
        throttledBy = connection
        readSource?.suspend()
        connection.whenBacklog(atMost: Self.resumeAt) { [weak self, weak connection] in
            guard let self, let connection, self.throttledBy === connection else { return }
            self.unthrottle()
        }
    }

    private func unthrottle() {
        guard throttledBy != nil else { return }
        throttledBy = nil
        readSource?.resume()
    }

    /// The client resizes the pty directly; follow it so the screen kept here wraps the same.
    private func syncSize() {
        var size = winsize()
        guard ioctl(masterFd, Self.getWindowSize, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return }
        if Int(size.ws_col) != terminal.cols || Int(size.ws_row) != terminal.rows {
            terminal.resize(cols: Int(size.ws_col), rows: Int(size.ws_row))
        }
    }

    private func reap(blocking: Bool) {
        guard !exited else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        // A blocking wait that fails means someone else reaped it; the status is unknown (-1).
        guard result == pid || (blocking && result < 0) else { return }
        // Output written just before exit is still in the pty. Bounded: a background job
        // may keep the pty open and keep writing.
        for _ in 0..<64 { if !readPty() { break } }
        finish(status: result == pid ? Self.exitCode(status) : -1)
    }

    private func finish(status: Int32) {
        exited = true
        exitWatcher?.cancel()
        exitWatcher = nil
        writer?.close()
        writer = nil
        // A suspended source never runs its cancel handler, which closes the master.
        unthrottle()
        if readerSuspended { readSource?.resume() }
        readSource?.cancel()
        readSource = nil
        try? client?.send(.exited(id: id, status: status))
        client = nil
        onExit?(self)
        onExit = nil
    }

    /// The exit code, or 128 + the signal for a shell killed by one.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

/// The headless terminal's delegate. Replies to terminal queries are dropped: the attached
/// app's own terminal answers them.
private final class HeadlessDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
