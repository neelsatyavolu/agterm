import AgTermCore
import AgTermSessionKit
import Foundation

/// A cloud machine's sessions helper, reached through its gateway (`agterm-sessions --listen`,
/// see docs/cloud-sessions-plan.md) over a WebSocket (`WebSocketPipe`). On Fly, `machine` picks
/// the user's machine behind the shared address. Each tab opens its own connection. In
/// development it comes from `AGTERM_CLOUD` (a wss:// URL, or ws:// / host:port on loopback),
/// `AGTERM_CLOUD_MACHINE` and `AGTERM_CLOUD_TOKEN`.
final class CloudHost: SessionEndpoint, CustomStringConvertible {
    private static let timeout: TimeInterval = 5
    private static let loopback: Set<String> = ["127.0.0.1", "::1", "localhost"]

    let url: URL
    let machine: String?
    private let token: String

    init(url: URL, machine: String? = nil, token: String) {
        self.url = url
        self.machine = machine
        self.token = token
    }

    var description: String { url.host ?? url.absoluteString }

    /// The machine set in the environment, if any.
    static let configured: CloudHost? = {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["AGTERM_CLOUD"], let token = env["AGTERM_CLOUD_TOKEN"], !token.isEmpty,
              let url = url(endpoint) else { return nil }
        return CloudHost(url: url, machine: env["AGTERM_CLOUD_MACHINE"], token: token)
    }()

    /// wss:// anywhere; ws:// (or a bare host:port) only on loopback, since it isn't encrypted.
    static func url(_ endpoint: String) -> URL? {
        let url = endpoint.contains("://") ? URL(string: endpoint) : TCPSocket.parse(endpoint).flatMap { _ in URL(string: "ws://\(endpoint)/") }
        guard let url, let host = url.host else { return nil }
        if url.scheme == "wss" { return url }
        guard url.scheme == "ws", loopback.contains(host) else {
            NSLog("agterm: a cloud machine needs wss://, or ws:// on loopback; ignoring %@", endpoint)
            return nil
        }
        return url
    }

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

    /// A connection running `argv` on the machine with plain pipes (see `WireMessage.exec`).
    func exec(_ argv: [String]) throws -> WireConnection {
        let connection = try socket()
        do {
            try connection.send(.auth(token: token))
            try connection.send(.exec(argv: argv))
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// Runs `argv` with no input and waits for it; returns its status and what it wrote to stderr.
    func run(_ argv: [String], timeout: TimeInterval = 30) throws -> (status: Int32, stderr: String) {
        let connection = try exec(argv)
        defer { connection.close() }
        try connection.send(.input(Data()))
        var stderr = ""
        while true {
            switch try connection.receive(timeout: timeout) {
            case .stderr(let bytes): stderr += String(decoding: bytes, as: UTF8.self)
            case .exited(_, let status): return (status, stderr)
            case .error(let text): throw WireError.remote(text)
            default: break
            }
        }
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
    /// A WebSocket to the gateway, before `auth`.
    private func socket() throws -> WireConnection {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        if let machine { request.setValue(machine, forHTTPHeaderField: "fly-force-instance-id") }
        // A stopped machine takes a few seconds to start when the proxy wakes it.
        return WireConnection(fd: try WebSocketPipe.open(request, timeout: machine == nil ? Self.timeout : 30))
    }

    private func connect() throws -> WireConnection {
        let connection = try socket()
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
