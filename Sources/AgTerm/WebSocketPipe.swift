import AgTermSessionKit
import Foundation

/// A WebSocket to a cloud machine's gateway, as a socket `WireConnection` can use. URLSession
/// does TLS; two loops move bytes between the WebSocket and one end of a socketpair, each waiting
/// for the other side to take the last chunk, which is the backpressure. A ping every 25 s keeps
/// proxies from closing a quiet connection.
final class WebSocketPipe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private static let chunk = 64 * 1024
    private static let pingInterval: TimeInterval = 25

    /// Opens `request` (ws:// or wss://) and returns the socket carrying the plain stream.
    static func open(_ request: URLRequest, timeout: TimeInterval) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var on: Int32 = 1
        for fd in pair { _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        let pipe = WebSocketPipe(inner: pair[1])
        do {
            try pipe.start(request, timeout: timeout)
        } catch {
            close(pair[0])
            close(pair[1])
            throw error
        }
        return pair[0]
    }

    private let inner: Int32
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let opened = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didOpen = false
    private var ended = false
    /// The two loops still using `inner`; the last one out closes it.
    private var loops = 2

    private init(inner: Int32) {
        self.inner = inner
    }

    private func start(_ request: URLRequest, timeout: TimeInterval) throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024 + 64
        task.resume()
        guard opened.wait(timeout: .now() + timeout) == .success, isOpen else {
            end()
            throw URLError(.cannotConnectToHost)
        }
        receive()
        Thread.detachNewThread { [self] in
            sendLoop()
            loopEnded()
        }
        schedulePing()
    }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOpen && !ended
    }

    // MARK: Loops

    /// WebSocket → socket. Writing blocks this session's own queue until the reader catches up.
    private func receive() {
        task.receive { [self] result in
            let bytes: Data
            switch result {
            case .success(.data(let data)): bytes = data
            case .success(.string(let text)): bytes = Data(text.utf8)
            default:
                end()
                return loopEnded()
            }
            guard WebSocketTransport.writeAll(inner, [UInt8](bytes)) else {
                end()
                return loopEnded()
            }
            receive()
        }
    }

    /// Socket → WebSocket, a chunk at a time, each sent before the next is read.
    private func sendLoop() {
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        let sent = DispatchSemaphore(value: 0)
        while true {
            let count = read(inner, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return end() }
            var failed = false
            task.send(.data(Data(buffer[0..<count]))) { error in
                failed = error != nil
                sent.signal()
            }
            sent.wait()
            if failed { return end() }
        }
    }

    private func schedulePing() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pingInterval) { [weak self] in
            guard let self, self.isOpen else { return }
            self.task.sendPing { _ in }
            self.schedulePing()
        }
    }

    /// Once: closes the WebSocket and shuts this end of the pair, so the other end reads end of
    /// stream and both loops stop.
    private func end() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        guard first else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        shutdown(inner, SHUT_RDWR)
        opened.signal()
    }

    private func loopEnded() {
        lock.lock()
        loops -= 1
        let last = loops == 0
        lock.unlock()
        if last { close(inner) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        didOpen = true
        lock.unlock()
        opened.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        end()
    }
}
