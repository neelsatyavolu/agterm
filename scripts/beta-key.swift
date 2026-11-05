// The Ed25519 half of scripts/beta-key.sh; run that instead. The private key only ever passes
// through stdin and stdout, between this and 1Password.
//   swift scripts/beta-key.swift new-item <title>       a new key pair, as a 1Password item template on stdout
//   swift scripts/beta-key.swift public                 private key on stdin → public key
//   swift scripts/beta-key.swift sign <name> [<days>]   private key on stdin → beta key
// The key format is BetaKey's (Sources/AgTermCore/BetaKey.swift).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func privateKeyFromStdin() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("the private key on stdin isn't a base64 Ed25519 key") }
    return key
}

func json(_ object: Any) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { fail("couldn't encode JSON") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "new-item" where args.count == 2:
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let item: [String: Any] = [
        "title": args[1],
        "category": "PASSWORD",
        "fields": [
            ["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password",
             "value": key.rawRepresentation.base64EncodedString()],
            ["id": "public_key", "type": "STRING", "label": "public key", "value": publicKey],
            ["id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain",
             "value": "Signs agterm beta keys (scripts/beta-key.sh). The password is the raw Ed25519 private key, base64. "
                + "The app embeds the public key in Sources/AgTerm/BetaChannel.swift."],
        ],
    ]
    FileHandle.standardOutput.write(json(item))
case "public" where args.count == 1:
    print(privateKeyFromStdin().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 2 || args.count == 3:
    let name = args[1].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { fail("the tester's name is empty") }
    let issued = Int(Date().timeIntervalSince1970)
    var payload: [String: Any] = ["name": name, "issued": issued]
    if args.count == 3 {
        guard let days = Int(args[2]), days > 0 else { fail("--days needs a whole number of days above 0") }
        payload["expires"] = issued + days * 86_400
    }
    let bytes = json(payload)
    let key = privateKeyFromStdin()
    guard let signature = try? key.signature(for: bytes) else { fail("couldn't sign") }
    print("agterm-beta-\(base64URL(bytes)).\(base64URL(signature))")
default:
    fail("usage: swift scripts/beta-key.swift new-item <title> | public | sign <name> [<days>]")
}
