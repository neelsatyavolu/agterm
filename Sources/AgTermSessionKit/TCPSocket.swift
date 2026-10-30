import Foundation

/// TCP sockets for the gateway (cloud sessions). Like `UnixSocket`: close-on-exec, no SIGPIPE,
/// and Nagle off so each keystroke goes out at once.
public enum TCPSocket {
    #if canImport(Darwin)
    private static let streamType = SOCK_STREAM
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    /// Connects to `host:port`, giving up after `timeout`.
    public static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var lastError = POSIXError(.EHOSTUNREACH)
        for address in try addresses(host: host, port: port, passive: false) {
            let fd = socket(address.family, streamType, 0)
            guard fd >= 0 else { continue }
            configure(fd)
            UnixSocket.setNonBlocking(fd)
            do {
                try finishConnect(fd, address: address, timeout: timeout)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                return fd
            } catch let error as POSIXError {
                lastError = error
                Foundation.close(fd)
            }
        }
        throw lastError
    }

    /// Binds and listens on `host:port`, non-blocking; port 0 picks a free one. Returns the
    /// descriptor and the port it got.
    public static func listen(host: String, port: UInt16) throws -> (fd: Int32, port: UInt16) {
        guard let address = try addresses(host: host, port: port, passive: true).first else { throw POSIXError(.EADDRNOTAVAIL) }
        let fd = socket(address.family, streamType, 0)
        guard fd >= 0 else { throw POSIXError.current }
        configure(fd)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        do {
            let bound = address.bytes.withUnsafeBytes { raw in
                Foundation.bind(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), address.length)
            }
            guard bound == 0, Foundation.listen(fd, 16) == 0 else { throw POSIXError.current }
            UnixSocket.setNonBlocking(fd)
            return (fd, try localPort(fd))
        } catch {
            Foundation.close(fd)
            throw error
        }
    }

    /// Prepares a descriptor from `socket` or `accept`.
    public static func configure(_ fd: Int32) {
        UnixSocket.configure(fd)
        var on: Int32 = 1
        _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Splits `host:port` (`[::1]:7600` for IPv6).
    public static func parse(_ endpoint: String) -> (host: String, port: UInt16)? {
        guard let colon = endpoint.lastIndex(of: ":"), let port = UInt16(endpoint[endpoint.index(after: colon)...]) else { return nil }
        var host = String(endpoint[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    // MARK: Private

    private struct Address {
        let family: Int32
        let bytes: [UInt8]
        var length: socklen_t { socklen_t(bytes.count) }
    }

    private static func addresses(host: String, port: UInt16, passive: Bool) throws -> [Address] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        hints.ai_flags = passive ? AI_PASSIVE : 0
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(first) }
        var found: [Address] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry?.pointee {
            if let address = info.ai_addr {
                let bytes = Array(UnsafeRawBufferPointer(start: address, count: Int(info.ai_addrlen)))
                found.append(Address(family: info.ai_family, bytes: bytes))
            }
            entry = info.ai_next
        }
        return found
    }

    private static func finishConnect(_ fd: Int32, address: Address, timeout: TimeInterval) throws {
        let result = address.bytes.withUnsafeBytes { raw in
            Foundation.connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), address.length)
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw POSIXError.current }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, Int32(max(0, timeout) * 1000))
        guard ready > 0 else { throw POSIXError(ready == 0 ? .ETIMEDOUT : POSIXError.current.code) }
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else { throw POSIXError.current }
        guard failure == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .ECONNREFUSED) }
    }

    private static func localPort(_ fd: Int32) throws -> UInt16 {
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard result == 0 else { throw POSIXError.current }
        return withUnsafeBytes(of: &storage) { raw in
            // sin_port and sin6_port sit at the same offset, in network byte order.
            UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self))
        }
    }
}
