import AgTermCore
import AgTermSessionKit
import Foundation

/// A cloud machine's sessions helper, reached through its gateway (`agterm-sessions --listen`,
/// see docs/cloud-sessions-plan.md). For now it is set with `AGTERM_CLOUD=<host:port>` and
/// `AGTERM_CLOUD_TOKEN`, and only on this Mac's loopback: the gateway speaks plain TCP, so a
/// machine elsewhere is reached through an SSH tunnel or a container's port forward until hosted
/// machines bring TLS. Each tab opens its own connection.
final class CloudHost: SessionEndpoint {
    private static let timeout: TimeInterval = 5
    private static let loopback: Set<String> = ["127.0.0.1", "::1", "localhost"]

    let host: String
    let port: UInt16
    private let token: String

    init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// The machine set in the environment, if any.
    static let configured: CloudHost? = {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["AGTERM_CLOUD"], let (host, port) = TCPSocket.parse(endpoint),
              let token = env["AGTERM_CLOUD_TOKEN"], !token.isEmpty else { return nil }
        guard loopback.contains(host) else {
            NSLog("agterm: AGTERM_CLOUD must be a loopback address (the gateway has no TLS yet); ignoring %@", endpoint)
            return nil
        }
        return CloudHost(host: host, port: port, token: token)
    }()

    func spawn(_ request: SpawnRequest) throws -> HelperLink {
        let (connection, info) = try open(.spawn(request))
        return HelperLink(endpoint: self, connection: connection, info: info, ptyFd: nil, showReplay: false)
    }

    func attach(id: String) throws -> HelperLink {
        let (connection, info) = try open(.attach(id: id))
        return HelperLink(endpoint: self, connection: connection, info: info, ptyFd: nil, showReplay: true)
    }

    /// The machine's shells, oldest first; nil if it doesn't answer.
    func list() -> [SessionInfo]? {
        guard let connection = try? connect() else { return nil }
        defer { connection.close() }
        guard (try? connection.send(.list)) != nil,
              case .sessions(let infos)? = try? connection.receive(timeout: Self.timeout) else { return nil }
        return infos
    }

    func reattach(id: String) throws -> (WireConnection, Int32?) {
        (try open(.attach(id: id)).0, nil)
    }

    /// A connection that sent `request` (spawn or attach) and got `attached` back.
    private func open(_ request: WireMessage) throws -> (WireConnection, SessionInfo) {
        let connection = try connect()
        do {
            try connection.send(request)
            switch try connection.receive(timeout: Self.timeout) {
            case .attached(let info): return (connection, info)
            case .error(let text): throw WireError.remote(text)
            default: throw WireError.unexpectedReply
            }
        } catch {
            connection.close()
            throw error
        }
    }

    /// Authenticated and greeted.
    private func connect() throws -> WireConnection {
        let connection = WireConnection(fd: try TCPSocket.connect(host: host, port: port, timeout: Self.timeout))
        do {
            try connection.send(.auth(token: token))
            let server = try connection.handshake(build: SessionHelper.buildID, timeout: Self.timeout)
            guard server.version == SessionWire.protocolVersion else { throw HelperHandshake.VersionMismatch(server: server.version) }
            return connection
        } catch {
            connection.close()
            throw error
        }
    }
}
