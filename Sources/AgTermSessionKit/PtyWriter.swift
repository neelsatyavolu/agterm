import Foundation

/// Writes input to a pty master on its own queue, in order, so a program that isn't reading its
/// input stalls only that queue, never the app or the helper. Owns the descriptor and closes it last.
public final class PtyWriter {
    private let fd: Int32
    private let queue = DispatchQueue(label: "agterm.pty-writer")
    private var closed = false
    // Under `lock`: bytes queued but not yet written or given up on, and who waits for fewer.
    private let lock = NSLock()
    private var pending = 0
    private var drainWatch: (bytes: Int, queue: DispatchQueue, handler: () -> Void)?

    public init(fd: Int32) {
        self.fd = fd
    }

    /// Input queued but not yet taken by the program.
    public var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// Calls `handler` once on `queue` when at most `bytes` are pending (soon, if that's already so).
    public func whenPending(atMost bytes: Int, on queue: DispatchQueue, _ handler: @escaping () -> Void) {
        lock.lock()
        drainWatch = (bytes, queue, handler)
        checkWatchLocked()
        lock.unlock()
    }

    public func write(_ bytes: ArraySlice<UInt8>) {
        let bytes = Array(bytes)
        lock.lock()
        pending += bytes.count
        lock.unlock()
        queue.async { [self] in
            defer { written(bytes.count) }
            guard !closed else { return }
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
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

    private func written(_ count: Int) {
        lock.lock()
        pending -= count
        checkWatchLocked()
        lock.unlock()
    }

    private func checkWatchLocked() {
        guard let watch = drainWatch, pending <= watch.bytes else { return }
        drainWatch = nil
        watch.queue.async(execute: watch.handler)
    }

    /// Closes the descriptor after the input already queued.
    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            Foundation.close(fd)
        }
    }
}
