import Foundation

/// How one Mac reaches another that lets it run tasks (Settings → Macs). The worker Mac shows
/// this as a pairing code, `agterm-mac:` plus base64url JSON, and the other Mac pastes it. The
/// secret keys the TLS link (a pre-shared key, so no certificates) and the gateway's token.
public struct MacPairing: Codable, Equatable, Sendable {
    public static let prefix = "agterm-mac:"
    /// 32 random bytes as base64url, without padding.
    public static let secretLength = 43
    private static let maxNameLength = 63

    /// The worker Mac's name: its Bonjour service name, and what `agterm-remote --mac` takes.
    public var name: String
    /// A name or address that reaches it off the local network too (`Studio.local`, a Tailscale name).
    public var host: String
    public var port: UInt16
    public var secret: String

    public init(name: String, host: String, port: UInt16, secret: String) {
        self.name = name
        self.host = host
        self.port = port
        self.secret = secret
    }

    public var code: String {
        let data = (try? JSONEncoder.sorted.encode(self)) ?? Data()
        return Self.prefix + Self.base64url(data)
    }

    /// Nil unless `code` is a whole, valid pairing code (spaces and line breaks around it are fine).
    public init?(code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(Self.prefix), let data = Self.data(base64url: String(text.dropFirst(Self.prefix.count))),
              let decoded = try? JSONDecoder().decode(MacPairing.self, from: data), decoded.isValid else { return nil }
        self = decoded
    }

    public var isValid: Bool {
        !name.isEmpty && name.count <= Self.maxNameLength && !host.isEmpty && port > 0
            && secret.count == Self.secretLength && secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// A new secret from `bytes` (32 of them; the app passes random ones).
    public static func secret(from bytes: [UInt8]) -> String {
        precondition(bytes.count == 32, "a pairing secret is 32 bytes")
        return base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
