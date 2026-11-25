import AgTermCore
import AgTermSessionKit
import Foundation
import Network

/// A paired Mac or Windows PC that runs commands for this one (Settings → Macs & PCs), reached
/// over `MacLink`. A PC runs agterm-worker, which takes the same link and frames.
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
            if pairing.isWindows {
                _ = try info()
                return nil
            }
            let result = try run(["/usr/bin/true"], timeout: Self.timeout)
            return result.status == 0 ? nil : "it answered, but couldn't run a command"
        } catch {
            return Self.explain(error)
        }
    }

    /// The Mac's home folder, for paths there (a PC's with forward slashes, `C:/Users/you`).
    func home() throws -> String {
        if pairing.isWindows { return try info().home }
        let result = try run(["/bin/sh", "-c", #"printf %s "$HOME""#], timeout: Self.timeout * 2)
        guard result.status == 0, result.stdout.hasPrefix("/") else { throw MacLink.ConnectError(description: "couldn't read its home folder") }
        return result.stdout
    }

    /// A Windows PC's agterm-worker: its version, home folder and PowerShell.
    func info() throws -> WindowsSync.Info {
        let result = try run([WindowsSync.worker, "info"], timeout: Self.timeout * 2)
        guard result.status == 0, let info = WindowsSync.parseInfo(result.stdout) else {
            throw MacLink.ConnectError(description: "it answered, but its agterm-worker didn't say what it is")
        }
        return info
    }

    /// Authenticated, ready for `exec`. A PC isn't on Bonjour: its name, then its addresses.
    private func connect() throws -> WireConnection {
        var endpoints = MacLink.endpoints(name: pairing.name, host: pairing.host, port: pairing.port)
        if pairing.isWindows {
            endpoints.removeFirst()
            endpoints += (pairing.addresses ?? []).compactMap { address in
                NWEndpoint.Port(rawValue: pairing.port).map { NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: $0) }
            }
        }
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
