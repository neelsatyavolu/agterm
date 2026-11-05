import Foundation

/// A one-request-per-connection JSON RPC server on a Unix socket, the shape agmux's room socket
/// uses: the client writes `{id, method, params}` and a newline, the server answers with
/// `{id, result}` or `{id, error: {message}}` and a newline, then closes. Only processes of
/// this user may connect. The app serves consult's team tools with it.
public final class LineRPCServer {
    public typealias Reply = (Result<Any, Error>) -> Void
    /// Called on `queue` for each request; call `reply` once, from any thread.
    public typealias Handler = (_ method: String, _ params: [String: Any], _ reply: @escaping Reply) -> Void

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    static let maxRequestBytes = 256 * 1024

    public let path: String
    private let fd: Int32
    private let source: DispatchSourceRead
    private let io = DispatchQueue(label: "agterm.line-rpc", qos: .utility, attributes: .concurrent)

    /// Listens at `path`, replacing a socket file a previous run left behind.
    public init(path: String, queue: DispatchQueue, handler: @escaping Handler) throws {
        self.path = path
        if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSocket {
            unlink(path)
        }
        let fd = try UnixSocket.listen(path: path)
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        let io = self.io
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                UnixSocket.configure(client)
                // A BSD socket inherits the listener's O_NONBLOCK; reads here block, with a timeout.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                io.async { Self.serve(client, queue: queue, handler: handler) }
            }
        }
        source.setCancelHandler { Foundation.close(fd) }
        source.resume()
    }

    public func stop() {
        source.cancel()
        unlink(path)
    }

    deinit { stop() }

    private static func serve(_ fd: Int32, queue: DispatchQueue, handler: @escaping Handler) {
        do {
            try UnixSocket.requirePeer(fd, uid: getuid())
        } catch {
            Foundation.close(fd)
            return
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(fd) else {
            Foundation.close(fd)
            return
        }
        let request = parse(line)
        guard let method = request.method else {
            write(encode(id: request.id, result: .failure(Failure("Expected {id, method, params}."))), to: fd)
            return
        }
        queue.async {
            var answered = false
            handler(method, request.params) { result in
                guard !answered else { return }
                answered = true
                write(encode(id: request.id, result: result), to: fd)
            }
        }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < maxRequestBytes {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return nil
    }

    static func parse(_ line: Data) -> (id: Any, method: String?, params: [String: Any]) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return (NSNull(), nil, [:]) }
        let method = (object["method"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (object["id"] ?? NSNull(), method, object["params"] as? [String: Any] ?? [:])
    }

    static func encode(id: Any, result: Result<Any, Error>) -> Data {
        var reply: [String: Any] = ["id": id]
        switch result {
        case .success(let value):
            reply["result"] = JSONSerialization.isValidJSONObject(["v": value]) ? value : NSNull()
        case .failure(let error):
            reply["error"] = ["message": error.localizedDescription]
        }
        var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"error":{"message":"bad reply"}}"#.utf8)
        data.append(0x0A)
        return data
    }

    /// Writes the reply and closes, off the caller's thread (often the main one) and with a send
    /// timeout, so a client that stops reading can't stall the app. Called once per connection.
    private static func write(_ data: Data, to fd: Int32) {
        DispatchQueue.global(qos: .utility).async { send(data, to: fd) }
    }

    private static func send(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent <= 0 { break }
                offset += sent
            }
        }
        Foundation.close(fd)
    }
}
