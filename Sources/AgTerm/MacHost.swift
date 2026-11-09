import AgTermCore
import AgTermSessionKit
import Foundation

/// A paired Mac that runs commands for this one (Settings → Macs), reached over `MacLink`.
/// Each command is its own connection, as with `CloudHost`.
final class MacHost: ExecHost, CustomStringConvertible {
    /// Set for `agterm --cloud-pipe` when rsync copies to a paired Mac: its pairing code.
    static let pairingVariable = "AGTERM_MAC_PAIRING"
    private static let timeout: TimeInterval = 5

    let pairing: MacPairing

    init(_ pairing: MacPairing) {
        self.pairing = pairing
    }

    var description: String { pairing.name }

    /// The Mac `agterm --cloud-pipe` was started for, if any.
    static var fromEnvironment: MacHost? {
        ProcessInfo.processInfo.environment[pairingVariable].flatMap(MacPairing.init(code:)).map(MacHost.init)
    }

    var environment: [String: String] { [Self.pairingVariable: pairing.code] }

    func exec(_ argv: [String]) throws -> WireConnection {
        let connection = try connect()
        do {
            try connection.send(.exec(argv: argv))
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// Whether it answers and runs a command; nil if so, else why not.
    func check() -> String? {
        do {
            let result = try run(["/usr/bin/true"], timeout: Self.timeout)
            return result.status == 0 ? nil : "it answered, but couldn't run a command"
        } catch {
            return Self.explain(error)
        }
    }

    /// The Mac's home folder, for paths there.
    func home() throws -> String {
        let result = try run(["/bin/sh", "-c", #"printf %s "$HOME""#], timeout: Self.timeout * 2)
        guard result.status == 0, result.stdout.hasPrefix("/") else { throw MacLink.ConnectError(description: "couldn't read its home folder") }
        return result.stdout
    }

    /// Authenticated, ready for `exec`.
    private func connect() throws -> WireConnection {
        let endpoints = MacLink.endpoints(name: pairing.name, host: pairing.host, port: pairing.port)
        let connection = WireConnection(fd: try MacLink.connect(endpoints, secret: pairing.secret, timeout: Self.timeout))
        do {
            try connection.send(.auth(token: MacLink.token(secret: pairing.secret)))
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    /// One line for a person: an unauthorized reply means it was given a new pairing code.
    static func explain(_ error: Error) -> String {
        if case WireError.remote(let text)? = error as? WireError, text == "unauthorized" {
            return "it has a new pairing code; pair again"
        }
        return "\(error)"
    }
}
