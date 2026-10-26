import AgTermCore
import AgTermSessionKit
import Foundation
import SwiftTerm

/// A shell kept by the `agterm-sessions` helper, so it can outlive the app. Output arrives as
/// `replay` and `output` frames, read off the socket on a background queue and handed to the view
/// on the main queue in order, with LocalProcess's backpressure: past 4 MiB waiting, the socket
/// isn't read until the backlog is under 1 MiB, and the helper in turn stops reading the shell's
/// pty. Input and resizes go straight to the pty master the helper passed with `attached`.
///
/// A lost connection reattaches (see `lost`); a link another client superseded stops for good.
/// Either way, when it can't go on the tab is told the shell exited, status unknown.
final class HelperLink: PtyLink {
    private static let highWater = 4 * 1024 * 1024
    private static let lowWater = 1 * 1024 * 1024
    /// Small frames are merged into the newest waiting chunk up to this size.
    private static let mergeLimit = 64 * 1024
    /// Longest the main queue feeds the view in one go, in nanoseconds.
    private static let timeSlice: UInt64 = 4_000_000
    private static let compactAfter = 32

    let sessionID: String?
    let shellPid: pid_t
    private(set) var ptyFd: Int32
    var onData: (([UInt8]) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private let id: String
    private let client: SessionHelper.Client
    private let readQueue = DispatchQueue(label: "agterm.helper-link")
    private var writer: PtyWriter
    /// Main queue: ended, detached, or the exit was delivered.
    private var closed = false

    // Shared with the read queue, under `lock`.
    private let lock = NSLock()
    private var connection: WireConnection
    /// `end()` or `detach()` was called.
    private var released = false
    private var exited = false
    private var exitStatus: Int32?
    private var pending: [[UInt8]] = []
    private var head = 0
    private var pendingBytes = 0
    private var paused = false
    private var drainScheduled = false

    // Read queue only.
    private var policy = ReattachPolicy()
    /// The helper said another client attached to this session.
    private var superseded = false

    /// `showReplay` is false for a new shell: its replay is of an empty screen, and would wipe
    /// what the tab already shows (restored history, What's New).
    init(client: SessionHelper.Client, connection: WireConnection, info: SessionInfo, ptyFd: Int32, showReplay: Bool) {
        self.client = client
        self.connection = connection
        id = info.id
        sessionID = info.id
        shellPid = info.pid
        self.ptyFd = ptyFd
        writer = PtyWriter(fd: ptyFd)
        listen(to: connection, showReplay: showReplay)
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        guard !closed, !bytes.isEmpty else { return }
        writer.write(bytes)
    }

    func resize(_ size: winsize) {
        guard !closed else { return }
        var size = size
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: ptyFd, windowSize: &size)
    }

    /// The helper sends SIGHUP to the shell and its foreground job, and SIGKILL 2 s later.
    func end() {
        guard let connection = release() else { return }
        try? connection.send(.kill(id: id, signal: SIGHUP))
        connection.closeAfterSending()
    }

    func detach() {
        release()?.close()
    }

    /// `end()` from any thread, for the app's exit (quitting ends shells until it detaches them).
    func endAtExit() {
        lock.lock()
        let live = !released && !exited
        let current = connection
        lock.unlock()
        if live { try? current.send(.kill(id: id, signal: SIGHUP)) }
    }

    // MARK: Read queue

    private func listen(to connection: WireConnection, showReplay: Bool) {
        connection.onMessage = { [weak self] message in
            switch message {
            case .output(let bytes): self?.enqueue(bytes)
            case .replay(let bytes) where showReplay: self?.enqueue(bytes)
            case .exited(let id, let status) where id == self?.id: self?.finish(status)
            case .error(let text) where text == SessionWire.superseded: self?.superseded = true
            default: break
            }
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lost(connection)
        }
        connection.startReading(queue: readQueue)
    }

    private func enqueue(_ bytes: Data) {
        lock.lock()
        guard !released else { return lock.unlock() }
        // Fast output arrives as many small frames; merged, the view parses big runs.
        if pending.count > head, pending[pending.count - 1].count < Self.mergeLimit {
            pending[pending.count - 1].append(contentsOf: bytes)
        } else {
            pending.append([UInt8](bytes))
        }
        pendingBytes += bytes.count
        let pause = !paused && pendingBytes >= Self.highWater
        if pause { paused = true }
        let schedule = !drainScheduled
        drainScheduled = true
        let current = connection
        lock.unlock()
        if pause { current.pauseReading() }
        if schedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    /// The shell exited (`status`), or can't be reached (nil). Delivered after the output before it.
    private func finish(_ status: Int32?) {
        lock.lock()
        guard !exited, !released else { return lock.unlock() }
        exited = true
        exitStatus = status
        let schedule = !drainScheduled
        drainScheduled = true
        let current = connection
        lock.unlock()
        current.close()
        if schedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    /// Reattaches, up to three times with backoff, unless superseded. Reattaching repaints the tab
    /// from the helper's replay, which wipes what only the app drew (restored history, What's New
    /// lines); it is rare, since the helper throttles the shell rather than drop a slow client, and
    /// takes the helper dropping the connection anyway or restarting.
    private func lost(_ dropped: WireConnection) {
        guard isCurrent(dropped) else { return }
        while let delay = policy.delay(after: superseded ? .superseded : .dropped) {
            Thread.sleep(forTimeInterval: delay)
            guard isCurrent(dropped) else { return }
            if let (fresh, _, fd) = try? client.open(.attach(id: id)) {
                policy.connected()
                return adopt(fresh, ptyFd: fd)
            }
        }
        finish(nil)
    }

    private func isCurrent(_ connection: WireConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection === self.connection && !released && !exited
    }

    private func adopt(_ fresh: WireConnection, ptyFd fd: Int32) {
        lock.lock()
        let keep = !released
        if keep {
            connection = fresh
            paused = false
        }
        lock.unlock()
        guard keep else {
            fresh.close()
            Darwin.close(fd)
            return
        }
        DispatchQueue.main.async { [weak self] in
            if let self { self.replacePty(fd) } else { Darwin.close(fd) }
        }
        listen(to: fresh, showReplay: true)
    }

    // MARK: Main queue

    private func replacePty(_ fd: Int32) {
        guard !closed else {
            Darwin.close(fd)
            return
        }
        writer.close()
        writer = PtyWriter(fd: fd)
        ptyFd = fd
    }

    private func drain() {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            lock.lock()
            guard head < pending.count else {
                pending.removeAll(keepingCapacity: true)
                head = 0
                pendingBytes = 0
                drainScheduled = false
                let ended = exited
                let status = exitStatus
                lock.unlock()
                if ended { deliverExit(status) }
                return
            }
            let chunk = pending[head]
            head += 1
            if head >= Self.compactAfter {
                pending.removeFirst(head)
                head = 0
            }
            pendingBytes -= chunk.count
            let resume = paused && pendingBytes <= Self.lowWater
            if resume { paused = false }
            let current = connection
            lock.unlock()
            if resume { current.resumeReading() }
            onData?(chunk)
            if DispatchTime.now().uptimeNanoseconds - start >= Self.timeSlice {
                DispatchQueue.main.async { [weak self] in self?.drain() }
                return
            }
        }
    }

    private func deliverExit(_ status: Int32?) {
        guard !closed else { return }
        closed = true
        writer.close()
        ptyFd = -1
        client.forget(self)
        onExit?(status)
    }

    /// Stops output and input for good. Returns the connection to close, or nil if already closed.
    private func release() -> WireConnection? {
        guard !closed else { return nil }
        closed = true
        lock.lock()
        released = true
        pending = []
        head = 0
        pendingBytes = 0
        let current = connection
        lock.unlock()
        writer.close()
        ptyFd = -1
        onData = nil
        onExit = nil
        client.forget(self)
        return current
    }
}

/// Writes input to a pty master on its own queue, in order, so a program that isn't reading its
/// input stalls only that queue, never the app. Owns the descriptor and closes it last.
final class PtyWriter {
    private let fd: Int32
    private let queue = DispatchQueue(label: "agterm.pty-writer")
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        let bytes = Array(bytes)
        queue.async { [self] in
            guard !closed else { return }
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EAGAIN {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 100)
                } else if !(count < 0 && errno == EINTR) {
                    return // EIO: the shell is gone.
                }
            }
        }
    }

    /// Closes the descriptor after the input already queued.
    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}
