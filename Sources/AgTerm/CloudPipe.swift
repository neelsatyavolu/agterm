import AgTermCore
import AgTermSessionKit
import Foundation

/// `agterm --cloud-pipe <host> <command…>`: rsync's remote shell for the cloud machine
/// (`rsync -e "agterm --cloud-pipe" … cloud:/path`). It runs the command words as they are
/// there, and passes stdin, stdout and stderr through the gateway (`WireMessage.exec`). Unlike
/// ssh it doesn't hand them to a shell: macOS's openrsync doesn't quote paths for one, so a
/// folder with a space in its name would split.
/// The machine is `CloudHost.configured`; `<host>` is ignored. Exits with the command's status,
/// or 255 if the machine can't be reached, as ssh does.
/// With `AGTERM_CLOUD_PROGRESS` set to a file, it keeps the number of bytes sent so far there.
enum CloudPipe {
    static let flag = "--cloud-pipe"
    static let progressVariable = "AGTERM_CLOUD_PROGRESS"
    private static let chunk = 64 * 1024
    private static let highWater = 1024 * 1024

    static func run(_ arguments: [String]) -> Never {
        let words = Array(arguments.drop { $0 != flag }.dropFirst(2))
        guard let cloud = CloudHost.configured, !words.isEmpty else { fail("usage: agterm \(flag) <host> <command…>, with AGTERM_CLOUD set") }
        signal(SIGPIPE, SIG_IGN)
        let connection: WireConnection
        do {
            connection = try cloud.exec(["/usr/bin/env"] + words)
        } catch {
            fail("agterm: can't reach the cloud machine: \(error)")
        }
        connection.onMessage = { message in
            switch message {
            case .output(let bytes): writeAll(STDOUT_FILENO, bytes)
            case .stderr(let bytes): writeAll(STDERR_FILENO, bytes)
            case .exited(_, let status): exit(status)
            case .error(let text): fail("agterm: cloud machine: \(text)")
            default: break
            }
        }
        connection.onClose = { fail("agterm: lost the cloud machine") }
        connection.startReading(queue: DispatchQueue(label: "agterm.cloud-pipe"))
        let reader = Thread { forwardInput(to: connection) }
        reader.start()
        // Once stdin ends nothing else holds the connection, and its output is still coming.
        withExtendedLifetime(connection) { dispatchMain() }
    }

    /// Stdin to the command, a chunk at a time, never more than `highWater` ahead of the network.
    private static func forwardInput(to connection: WireConnection) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 8)
        defer { buffer.deallocate() }
        let progress = ProcessInfo.processInfo.environment[progressVariable].map { open($0, O_WRONLY | O_CLOEXEC) } ?? -1
        var sent = 0
        var reported = Date.distantPast
        while true {
            let count = read(STDIN_FILENO, buffer, chunk)
            // openrsync may hand over a non-blocking socket.
            if count < 0 && errno == EAGAIN { wait(for: STDIN_FILENO, POLLIN); continue }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                try? connection.send(.input(Data()))
                return
            }
            while connection.backlogBytes > highWater { usleep(2_000) }
            guard (try? connection.send(.input(Data(bytes: buffer, count: count)))) != nil else { return }
            sent += count
            if progress >= 0, Date().timeIntervalSince(reported) > 0.25 {
                reported = Date()
                let line = Array("\(sent)\n".utf8)
                _ = ftruncate(progress, 0)
                _ = pwrite(progress, line, line.count, 0)
            }
        }
    }

    /// Blocking on purpose: a slow reader stalls this connection, and the gateway in turn.
    private static func writeAll(_ fd: Int32, _ bytes: Data) {
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count > 0 {
                    offset += count
                } else if errno == EAGAIN {
                    wait(for: fd, POLLOUT)
                } else if errno != EINTR {
                    exit(255)
                }
            }
        }
    }

    private static func wait(for fd: Int32, _ event: Int32) {
        var poller = pollfd(fd: fd, events: Int16(event), revents: 0)
        _ = poll(&poller, 1, -1)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(255)
    }
}
