import AgTermCore
import Foundation

/// How the app opens a connection to the helper: connect, then trade `hello`s. A helper that
/// speaks another protocol version is refused, and the app runs its tabs in-process instead.
public enum HelperHandshake {
    public struct VersionMismatch: Error, Equatable {
        public let server: Int

        public init(server: Int) {
            self.server = server
        }
    }

    /// The greeted connection and the helper's build. Throws the connect error when nothing
    /// serves `socket`, or `VersionMismatch`.
    public static func connect(socket: String, build: String, expectVersion: Int = SessionWire.protocolVersion,
                               timeout: TimeInterval = 1) throws -> (connection: WireConnection, build: String) {
        let connection = try WireConnection.connect(path: socket)
        do {
            let server = try connection.handshake(build: build, version: expectVersion, timeout: timeout)
            guard server.version == expectVersion else { throw VersionMismatch(server: server.version) }
            return (connection, server.build)
        } catch {
            connection.close()
            throw error
        }
    }
}
