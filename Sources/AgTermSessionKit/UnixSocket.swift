import Foundation

/// Unix-domain stream sockets. Every descriptor made here is close-on-exec, so shells the
/// helper spawns never inherit them, and never raises SIGPIPE.
enum UnixSocket {
    static func connect(path: String) throws -> Int32 {
        var address = try self.address(path)
        let fd = try make()
        let result = withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let error = POSIXError.current
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Binds and listens at `path` (mode 0600), non-blocking. Throws EADDRINUSE if the path exists.
    static func listen(path: String) throws -> Int32 {
        var address = try self.address(path)
        let fd = try make()
        do {
            guard withSockaddr(&address, { Darwin.bind(fd, $0, $1) }) == 0 else { throw POSIXError.current }
            guard chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else { throw POSIXError.current }
            setNonBlocking(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Prepares a descriptor from `socket` or `accept`.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    private static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }
        configure(fd)
        return fd
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw WireError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        return address
    }

    private static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
