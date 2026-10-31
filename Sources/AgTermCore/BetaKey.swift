#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// A beta key from scripts/beta-key.sh: `agterm-beta-<payload>.<signature>`, both base64url.
/// The payload is JSON with the tester's name, when the key was made and, optionally, when it
/// stops working (Unix seconds); the signature is Ed25519 over the payload's bytes.
public struct BetaKey: Equatable {
    public static let prefix = "agterm-beta-"

    public let name: String
    public let issued: Date
    public let expires: Date?

    public enum Problem: Error, Equatable {
        case malformed
        case badSignature
        case expired(Date)
    }

    private struct Payload: Decodable {
        let name: String
        let issued: Int
        let expires: Int?
    }

    /// Checks the signature against `publicKey` (raw 32 bytes) and the expiry against `now`.
    /// Whitespace and line breaks from pasting are ignored.
    public init(verifying text: String, publicKey: Data, now: Date = Date()) throws {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.hasPrefix(Self.prefix) else { throw Problem.malformed }
        let parts = compact.dropFirst(Self.prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Self.base64URLDecode(parts[0]), let signature = Self.base64URLDecode(parts[1]),
              let fields = try? JSONDecoder().decode(Payload.self, from: payload),
              !fields.name.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw Problem.malformed }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload)
        else { throw Problem.badSignature }
        name = fields.name
        issued = Date(timeIntervalSince1970: TimeInterval(fields.issued))
        expires = fields.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if let expires, expires <= now { throw Problem.expired(expires) }
    }

    static func base64URLDecode<S: StringProtocol>(_ text: S) -> Data? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
#endif
