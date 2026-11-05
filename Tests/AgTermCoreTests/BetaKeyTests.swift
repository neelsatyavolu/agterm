#if canImport(CryptoKit)
import CryptoKit
import XCTest
@testable import AgTermCore

final class BetaKeyTests: XCTestCase {
    private let signer = Curve25519.Signing.PrivateKey()
    private var publicKey: Data { signer.publicKey.rawRepresentation }
    private let issued = 1_793_404_260

    /// Made the way scripts/beta-key.swift makes them.
    private func makeKey(_ payload: [String: Any], signer: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = try (signer ?? self.signer).signature(for: bytes)
        return "agterm-beta-\(base64URL(bytes)).\(base64URL(signature))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func problem(_ text: String, now: Date? = nil) -> BetaKey.Problem? {
        do {
            _ = try BetaKey(verifying: text, publicKey: publicKey, now: now ?? Date(timeIntervalSince1970: TimeInterval(issued)))
            return nil
        } catch {
            return error as? BetaKey.Problem
        }
    }

    func testValidKeyPasses() throws {
        let text = try makeKey(["name": "Ada Lovelace", "issued": issued])
        let key = try BetaKey(verifying: text, publicKey: publicKey)
        XCTAssertEqual(key.name, "Ada Lovelace")
        XCTAssertEqual(key.issued, Date(timeIntervalSince1970: TimeInterval(issued)))
        XCTAssertNil(key.expires)
        // Pasting can add spaces and line breaks.
        let pasted = "  " + text.prefix(30) + "\n" + text.dropFirst(30) + "\n"
        XCTAssertEqual(try BetaKey(verifying: pasted, publicKey: publicKey), key)
    }

    func testKeyFromTheScriptPasses() throws {
        // `scripts/beta-key.swift sign "Test Person" 3` with a throwaway key pair.
        let script = "agterm-beta-eyJleHBpcmVzIjoxNzkzNjYzNDYwLCJpc3N1ZWQiOjE3OTM0MDQyNjAsIm5hbWUiOiJUZXN0IFBlcnNvbiJ9."
            + "Sjq0SfRvYp1DQlfx_Ex4On-oUTHzg_I55S4K8qdSx2ZScw3uOm78B5uI1Y5NRzbj-spjSlb9kx3zV5z7CJv-DA"
        let throwaway = try XCTUnwrap(Data(base64Encoded: "OTVIB0nJ0TsuF9LE56Iw+FyCw2hDNShSKSAprUShJEE="))
        let key = try BetaKey(verifying: script, publicKey: throwaway, now: Date(timeIntervalSince1970: 1_793_404_300))
        XCTAssertEqual(key.name, "Test Person")
        XCTAssertEqual(key.expires, Date(timeIntervalSince1970: 1_793_663_460))
        XCTAssertThrowsError(try BetaKey(verifying: script, publicKey: publicKey, now: Date(timeIntervalSince1970: 1_793_404_300)))
    }

    func testTamperedKeysFail() throws {
        let text = try makeKey(["name": "Ada", "issued": issued])
        let parts = text.dropFirst(BetaKey.prefix.count).split(separator: ".")
        // Someone else's name, with the original signature.
        let renamed = try makeKey(["name": "Eve", "issued": issued])
        let renamedPayload = renamed.dropFirst(BetaKey.prefix.count).split(separator: ".")[0]
        XCTAssertEqual(problem(BetaKey.prefix + renamedPayload + "." + parts[1]), .badSignature)
        // One changed character in the signature.
        var signature = Array(parts[1])
        signature[5] = signature[5] == "A" ? "B" : "A"
        XCTAssertEqual(problem(BetaKey.prefix + parts[0] + "." + String(signature)), .badSignature)
        // Signed with another key.
        XCTAssertEqual(problem(try makeKey(["name": "Ada", "issued": issued], signer: Curve25519.Signing.PrivateKey())), .badSignature)
    }

    func testExpiredKeyFails() throws {
        let expires = issued + 86_400
        let text = try makeKey(["name": "Ada", "issued": issued, "expires": expires])
        XCTAssertNil(problem(text, now: Date(timeIntervalSince1970: TimeInterval(expires - 1))))
        XCTAssertEqual(problem(text, now: Date(timeIntervalSince1970: TimeInterval(expires))),
                       .expired(Date(timeIntervalSince1970: TimeInterval(expires))))
    }

    func testMalformedKeysFail() throws {
        let good = try makeKey(["name": "Ada", "issued": issued])
        let body = good.dropFirst(BetaKey.prefix.count)
        for text in ["", "hello", String(body), "agterm-beta-", "agterm-beta-abc", "agterm-beta-abc.def.ghi",
                     "agterm-beta-" + body.replacingOccurrences(of: ".", with: ""), "agterm-beta-***." + body.split(separator: ".")[1]] {
            XCTAssertEqual(problem(text), .malformed, text)
        }
        XCTAssertEqual(problem(try makeKey(["name": " ", "issued": issued])), .malformed)
        XCTAssertEqual(problem(try makeKey(["issued": issued])), .malformed)
        XCTAssertEqual(problem(try makeKey(["name": "Ada", "issued": "today"])), .malformed)
    }
}
#endif
