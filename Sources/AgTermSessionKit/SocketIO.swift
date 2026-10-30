import AgTermCore
import Foundation

public enum WireError: Error, Equatable {
    case closed
    case timedOut
    case pathTooLong
    /// The process serving the socket runs as another user.
    case untrustedPeer
    /// The other side answered with `error`.
    case remote(String)
    case unexpectedReply
}

/// One end of a helper connection: framed `WireMessage`s, plus file descriptors passed as
/// SCM_RIGHTS on the same `sendmsg` as a message's bytes.
///
/// Two ways to use it: blocking (`send` / `receive`, for clients and tests), or event-driven
/// after `startReading(queue:)`, where messages arrive on `onMessage` and sends queue up
/// instead of blocking. A backlog more than `maxQueuedBytes` beyond the largest message in it
/// closes the connection (one big replay is fine; output piling up behind it is not): a
/// client that far behind reattaches and gets a fresh replay.
public final class WireConnection {
    public static let maxQueuedBytes = 8 * 1024 * 1024
    private static let readSize = 64 * 1024
    private static let controlSize = 256
    /// `CMSG_DATA` offset and record alignment: 12 and 4 on Darwin (three 32-bit fields), 16 and 8
    /// on Linux (`cmsg_len` is a size_t).
    private static let cmsgHeader = MemoryLayout<cmsghdr>.size
    private static let cmsgAlign = MemoryLayout<cmsghdr>.alignment
    #if canImport(Darwin)
    private static let sendFlags: Int32 = 0
    #else
    /// Linux sockets have no SO_NOSIGPIPE, so each send asks not to raise SIGPIPE.
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    public let fd: Int32
    /// Called on the reading queue for each message, after `startReading`.
    public var onMessage: ((WireMessage) -> Void)?
    /// Called once on the reading queue when an event-driven connection closes, from either end.
    public var onClose: (() -> Void)?

    private struct Pending {
        let data: Data
        /// Size of the whole message this frame belongs to.
        let messageBytes: Int
        var offset = 0
        /// A dup of the descriptor to pass; closed once it has gone out.
        var fd: Int32?
    }

    private let lock = NSLock()
    private var closed = false
    private var closeWhenFlushed = false
    private var outbox: [Pending] = []
    private var queuedBytes = 0
    private var receivedFDs: [Int32] = []
    private var inbox = Data()
    private var queue: DispatchQueue?
    private var readSource: DispatchSourceRead?
    private var readPaused = false
    /// Called once the backlog is down to `bytes` (see `whenBacklog`).
    private var backlogWatch: (bytes: Int, handler: () -> Void)?
    private var writeSource: DispatchSourceWrite?
    /// Sources still registered on `fd`; the descriptor closes after the last cancel handler.
    private let liveSources = DispatchGroup()
    private let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: readSize, alignment: 8)
    private let controlBuffer = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        lock.lock()
        closeLocked(notify: false)
        lock.unlock()
        readBuffer.deallocate()
        controlBuffer.deallocate()
    }

    /// Connects to the helper at `path`, refusing a socket directory others could write to
    /// (`SessionPathError`) or a server running as another user (`WireError.untrustedPeer`).
    public static func connect(path: String) throws -> WireConnection {
        try SessionPaths.verifyDirectory((path as NSString).deletingLastPathComponent)
        let fd = try UnixSocket.connect(path: path)
        do {
            try UnixSocket.requirePeer(fd, uid: getuid())
        } catch {
            Foundation.close(fd)
            throw error
        }
        return WireConnection(fd: fd)
    }

    /// Sends `hello` and returns the server's `hello`. The caller compares versions.
    public func handshake(build: String, version: Int = SessionWire.protocolVersion,
                          timeout: TimeInterval = 5) throws -> (version: Int, build: String) {
        try send(.hello(version: version, build: build))
        switch try receive(timeout: timeout) {
        case .hello(let version, let build): return (version, build)
        case .error(let text): throw WireError.remote(text)
        default: throw WireError.unexpectedReply
        }
    }

    /// Queues `m` (split into several frames when it is `output` or `replay` data larger than
    /// one frame) and writes what the socket takes. `fd`, if given, is dup'ed now and passed
    /// with the first bytes of the message.
    public func send(_ m: WireMessage, fd passing: Int32? = nil) throws {
        let frames = Self.frames(for: m)
        let messageBytes = frames.reduce(0) { $0 + $1.count }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw WireError.closed }
        var dup: Int32?
        if let passing {
            dup = fcntl(passing, F_DUPFD_CLOEXEC, 0)
            guard dup! >= 0 else { throw POSIXError.current }
        }
        for (index, frame) in frames.enumerated() {
            outbox.append(Pending(data: frame, messageBytes: messageBytes, fd: index == 0 ? dup : nil))
            queuedBytes += frame.count
        }
        try flushLocked()
        guard queue != nil, queuedBytes > Self.maxQueuedBytes else { return }
        let largest = outbox.lazy.map(\.messageBytes).max() ?? 0
        if queuedBytes - largest > Self.maxQueuedBytes {
            closeLocked()
            throw WireError.closed
        }
    }

    /// Bytes queued but not yet written to the socket.
    public var backlogBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedBytes
    }

    /// Calls `handler` once, on the reading queue, when the backlog is down to `bytes` (soon, if
    /// it already is). Replaces any earlier watch; never called if the connection closes first.
    public func whenBacklog(atMost bytes: Int, _ handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        backlogWatch = (bytes, handler)
        checkBacklogLocked()
    }

    /// The process at the other end.
    public var peerPID: pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
        #else
        guard let pid = try? UnixSocket.peerCredentials(fd).pid, pid > 0 else { return nil }
        return pid
        #endif
    }

    /// Closes once everything queued has been written (right away if nothing is).
    public func closeAfterSending() {
        lock.lock()
        defer { lock.unlock() }
        closeWhenFlushed = true
        if outbox.isEmpty { closeLocked() }
    }

    /// Blocks for the next message. Throws `timedOut`, or `closed` at end of stream, or the
    /// decode error (after closing: a bad frame poisons the stream).
    public func receive(timeout: TimeInterval? = nil) throws -> WireMessage {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let message = try decodeNext() { return message }
            if let deadline {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let millis = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                let ready = poll(&poller, 1, millis)
                if ready == 0 { throw WireError.timedOut }
                if ready < 0 && errno != EINTR { throw POSIXError.current }
                if ready < 0 { continue }
            }
            let count = readOnce()
            if count == 0 || (count < 0 && errno != EINTR) { throw WireError.closed }
        }
    }

    /// The next descriptor received with a message, if any. The caller owns it.
    public func takeFD() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return receivedFDs.isEmpty ? nil : receivedFDs.removeFirst()
    }

    /// Switches to event-driven mode: non-blocking, messages delivered on `queue`.
    public func startReading(queue: DispatchQueue) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, self.queue == nil else { return }
        self.queue = queue
        UnixSocket.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        liveSources.enter()
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [liveSources] in liveSources.leave() }
        readSource = source
        source.resume()
        // Messages read by an earlier blocking `receive` may be waiting in the inbox already.
        queue.async { [weak self] in self?.deliverBuffered() }
    }

    /// Stops taking bytes off the socket (backpressure: the sender's backlog grows instead).
    public func pauseReading() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !readPaused, let readSource else { return }
        readSource.suspend()
        readPaused = true
    }

    public func resumeReading() {
        lock.lock()
        defer { lock.unlock() }
        guard readPaused else { return }
        readSource?.resume()
        readPaused = false
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    // MARK: Reading

    private func readAvailable() {
        let count = readOnce()
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { return close() }
        deliverBuffered()
    }

    private func deliverBuffered() {
        do {
            while !isClosed, let message = try decodeNext() { onMessage?(message) }
        } catch {
            // decodeNext already closed the connection.
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func decodeNext() throws -> WireMessage? {
        do {
            return try WireFrame.decode(&inbox)
        } catch {
            close()
            throw error
        }
    }

    /// One `recvmsg`: bytes go to `inbox`, passed descriptors to `receivedFDs`.
    private func readOnce() -> Int {
        var iov = iovec(iov_base: readBuffer, iov_len: Self.readSize)
        var message = msghdr()
        let count = withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
            message.msg_iov = iovPointer
            message.msg_iovlen = 1
            message.msg_control = controlBuffer
            message.msg_controllen = .init(Self.controlSize)
            return recvmsg(fd, &message, 0)
        }
        guard count >= 0 else { return count }
        let fds = Self.descriptors(in: controlBuffer, length: Int(message.msg_controllen))
        if !fds.isEmpty {
            lock.lock()
            if closed { fds.forEach { Foundation.close($0) } } else { receivedFDs += fds }
            lock.unlock()
        }
        inbox.append(readBuffer.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }

    private static func descriptors(in control: UnsafeMutableRawPointer, length: Int) -> [Int32] {
        var fds: [Int32] = []
        var offset = 0
        while offset + cmsgHeader <= length {
            let header = control.load(fromByteOffset: offset, as: cmsghdr.self)
            let cmsgLength = Int(header.cmsg_len)
            guard cmsgLength >= cmsgHeader, offset + cmsgLength <= length else { break }
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == Int32(SCM_RIGHTS) {
                for index in 0..<(cmsgLength - cmsgHeader) / 4 {
                    let fd = control.load(fromByteOffset: offset + cmsgHeader + index * 4, as: Int32.self)
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    fds.append(fd)
                }
            }
            offset += (cmsgLength + cmsgAlign - 1) & ~(cmsgAlign - 1)
        }
        return fds
    }

    // MARK: Writing (lock held)

    private func flushLocked() throws {
        while !outbox.isEmpty {
            let written = write(outbox[0])
            if written > 0 {
                // The kernel attaches the descriptor to the first bytes it accepts, so it is gone now.
                if let passed = outbox[0].fd { Foundation.close(passed); outbox[0].fd = nil }
                outbox[0].offset += written
                queuedBytes -= written
                if outbox[0].offset == outbox[0].data.count { outbox.removeFirst() }
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                checkBacklogLocked()
                return armWriteSource()
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                closeLocked()
                throw WireError.closed
            }
        }
        if let source = writeSource {
            writeSource = nil
            source.cancel()
        }
        checkBacklogLocked()
        if closeWhenFlushed { closeLocked() }
    }

    private func checkBacklogLocked() {
        guard let watch = backlogWatch, queuedBytes <= watch.bytes, let queue else { return }
        backlogWatch = nil
        queue.async(execute: watch.handler)
    }

    private func write(_ pending: Pending) -> Int {
        pending.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress! + pending.offset),
                            iov_len: raw.count - pending.offset)
            return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                guard let passing = pending.fd else { return sendmsg(fd, &message, Self.sendFlags) }
                let length = Self.cmsgHeader + 4
                let control = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 8)
                defer { control.deallocate() }
                var header = cmsghdr()
                header.cmsg_len = .init(length)
                header.cmsg_level = SOL_SOCKET
                header.cmsg_type = Int32(SCM_RIGHTS)
                control.storeBytes(of: header, toByteOffset: 0, as: cmsghdr.self)
                control.storeBytes(of: passing, toByteOffset: Self.cmsgHeader, as: Int32.self)
                message.msg_control = control
                message.msg_controllen = .init(length)
                return sendmsg(fd, &message, Self.sendFlags)
            }
        }
    }

    private func armWriteSource() {
        guard writeSource == nil, let queue else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        liveSources.enter()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            try? self.flushLocked()
        }
        source.setCancelHandler { [liveSources] in liveSources.leave() }
        writeSource = source
        source.resume()
    }

    private func closeLocked(notify: Bool = true) {
        guard !closed else { return }
        closed = true
        for pending in outbox { if let passed = pending.fd { Foundation.close(passed) } }
        outbox = []
        queuedBytes = 0
        backlogWatch = nil
        receivedFDs.forEach { Foundation.close($0) }
        receivedFDs = []
        guard let queue else { Foundation.close(fd); return }
        // A suspended source never runs its cancel handler (and crashes when released).
        if readPaused { readSource?.resume(); readPaused = false }
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        liveSources.notify(queue: queue) { [fd] in Foundation.close(fd) }
        guard notify else { return }
        queue.async { [self] in
            onClose?()
            onClose = nil
            onMessage = nil
        }
    }

    private static func frames(for m: WireMessage) -> [Data] {
        let bytes: Data
        let wrap: (Data) -> WireMessage
        switch m {
        case .output(let data) where data.count > WireFrame.maxPayload: (bytes, wrap) = (data, WireMessage.output)
        case .replay(let data) where data.count > WireFrame.maxPayload: (bytes, wrap) = (data, WireMessage.replay)
        default: return [WireFrame.encode(m)]
        }
        return stride(from: bytes.startIndex, to: bytes.endIndex, by: WireFrame.maxPayload).map {
            WireFrame.encode(wrap(bytes[$0..<min($0 + WireFrame.maxPayload, bytes.endIndex)]))
        }
    }
}
