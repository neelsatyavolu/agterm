import AgTermCore
import AgTermSessionKit
import Foundation
import SwiftTerm

/// Where a `HelperLink` reconnects after losing its connection: this Mac's sessions helper, or
/// a cloud machine's gateway.
protocol SessionEndpoint: AnyObject {
    /// A new connection attached to session `id`, with the pty master if this end passes one.
    func reattach(id: String) throws -> (WireConnection, Int32?)
}

/// A shell kept by the sessions helper, so it can outlive the app. Output arrives as
/// `replay` and `output` frames, read off the socket on a background queue and handed to the view
/// on the main queue in order, with LocalProcess's backpressure: past 4 MiB waiting, the socket
/// isn't read until the backlog is under 1 MiB, and the helper in turn stops reading the shell's
/// pty. Input and resizes go straight to the pty master the helper passed with `attached`; a
/// shell on a cloud machine has none here, so they go as `input` and `resize` frames, and the
/// link reports no shell pid (the helper's pid means nothing on this Mac).
///
/// A lost connection reattaches (see `lost`); a link another client superseded stops for good.
/// Either way, when it can't go on the tab is told the shell exited, status unknown.
final class HelperLink: PtyLink {
    private static let highWater = 4 * 1024 * 1024
    private static let lowWater = 1 * 1024 * 1024
    /// Small frames are merged into the newest waiting chunk up to this size.
    private static let mergeLimit = 64 * 1024
    /// Largest waiting chunk: a big replay or frame is split, so feeding one chunk stays well
    /// inside the time slice.
    private static let chunkLimit = 256 * 1024
    /// Longest the main queue feeds the view in one go, in nanoseconds.
    private static let timeSlice: UInt64 = 4_000_000
    private static let compactAfter = 32

    let sessionID: String?
    let shellPid: pid_t
    private(set) var ptyFd: Int32
    var onData: (([UInt8]) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private let id: String
    private let endpoint: SessionEndpoint
    private let readQueue = DispatchQueue(label: "agterm.helper-link")
    /// Nil for a cloud shell, whose input goes over the connection.
    private var writer: PtyWriter?
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
    /// A cloud shell's latest size, sent again after a reattach (one made meanwhile was lost).
    private var window: WindowSize?

    // Read queue only.
    private var policy = ReattachPolicy()
    /// The helper said another client attached to this session.
    private var superseded = false

    /// `showReplay` is false for a new shell: its replay is of an empty screen, and would wipe
    /// what the tab already shows (restored history, What's New).
    init(endpoint: SessionEndpoint, connection: WireConnection, info: SessionInfo, ptyFd: Int32?, showReplay: Bool) {
        self.endpoint = endpoint
        self.connection = connection
        id = info.id
        sessionID = info.id
        shellPid = ptyFd == nil ? 0 : info.pid
        self.ptyFd = ptyFd ?? -1
        writer = ptyFd.map(PtyWriter.init)
        listen(to: connection, showReplay: showReplay)
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        guard !closed, !bytes.isEmpty else { return }
        if let writer { return writer.write(bytes) }
        try? currentConnection.send(.input(Data(bytes)))
    }

    func resize(_ size: winsize) {
        guard !closed else { return }
        guard writer != nil else {
            let window = WindowSize(cols: size.ws_col, rows: size.ws_row, width: size.ws_xpixel, height: size.ws_ypixel)
            lock.lock()
            self.window = window
            let current = connection
            lock.unlock()
            try? current.send(.resize(window))
            return
        }
        var size = size
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: ptyFd, windowSize: &size)
    }

    private var currentConnection: WireConnection {
        lock.lock()
        defer { lock.unlock() }
        return connection
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
        var offset = bytes.startIndex
        if pending.count > head, pending[pending.count - 1].count < Self.mergeLimit {
            let take = min(bytes.count, Self.chunkLimit - pending[pending.count - 1].count)
            pending[pending.count - 1].append(contentsOf: bytes[offset..<offset + take])
            offset += take
        }
        while offset < bytes.endIndex {
            let end = min(offset + Self.chunkLimit, bytes.endIndex)
            pending.append([UInt8](bytes[offset..<end]))
            offset = end
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
            if let (fresh, fd) = try? endpoint.reattach(id: id) {
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

    /// Runs on the read queue, so `fresh` delivers nothing until this returns. It is reading
    /// (and non-blocking) before the main queue can send on it.
    private func adopt(_ fresh: WireConnection, ptyFd fd: Int32?) {
        listen(to: fresh, showReplay: true)
        lock.lock()
        let keep = !released
        if keep {
            connection = fresh
            paused = false
        }
        let window = self.window
        lock.unlock()
        guard keep else {
            fresh.close()
            fd.map { _ = Darwin.close($0) }
            return
        }
        if let fd {
            DispatchQueue.main.async { [weak self] in
                if let self { self.replacePty(fd) } else { Darwin.close(fd) }
            }
        } else if let window {
            try? fresh.send(.resize(window))
        }
    }

    // MARK: Main queue

    private func replacePty(_ fd: Int32) {
        guard !closed else {
            Darwin.close(fd)
            return
        }
        writer?.close()
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
        writer?.close()
        ptyFd = -1
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
        writer?.close()
        ptyFd = -1
        onData = nil
        onExit = nil
        return current
    }
}
