import Foundation

/// Which login (Claude or Codex account) ran a session, as the opaque identity hash agmux
/// uses for the same login: agmux's `provider_accounts::activity::claude_hash` and
/// `provider_accounts::profile::team_identity_hash`, so one login has one hash in agmux,
/// agterm and the team pool. Read from local files only; never contacts a provider.
public enum LoginIdentity {
    /// Claude's identity from the `oauthAccount` object Claude Code keeps in `.claude.json`:
    /// `claude:account-org:["<accountUuid>","<orgId>"]`, else `claude:email-org:[…]`.
    public static func claudeIdentity(oauthAccount: [String: Any]) -> String? {
        let uuid = text(oauthAccount["accountUuid"]), org = text(oauthAccount["organizationUuid"])
        guard let org else { return nil }
        if let uuid { return "claude:account-org:" + compactJSON([uuid, org]) }
        guard let email = text(oauthAccount["emailAddress"]) else { return nil }
        return "claude:email-org:" + compactJSON([email.lowercased(), org])
    }

    /// sha256 of `["claude", identity]` as serde_json writes it.
    public static func claudeHash(identity: String) -> String {
        hex(SHA256.digest(Array(compactJSON(["claude", identity]).utf8)))
    }

    /// The login's email, shown to the team only when its owner turned that on.
    public static func claudeLabel(oauthAccount: [String: Any]) -> String? {
        text(oauthAccount["emailAddress"])
    }

    /// Hash and email for the login a `.claude.json` holds, or nil when it holds none.
    public static func claude(configJSON data: Data) -> (hash: String, label: String?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let identity = claudeIdentity(oauthAccount: account) else { return nil }
        return (claudeHash(identity: identity), claudeLabel(oauthAccount: account))
    }

    /// Codex's pool identity hash from `auth.json`: sha256 of `["codex", account_id, sub]`,
    /// workspace plus seat (the id token's subject), never the email.
    public static func codexHash(authJSON data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let account = tokens["account_id"] as? String,
              let subject = jwtSubject(tokens["id_token"] as? String ?? "") else { return nil }
        return hex(SHA256.digest(Array(compactJSON(["codex", account, subject]).utf8)))
    }

    /// The `sub` claim of a JWT's payload; decoding does not verify the token.
    static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // Rust decodes URL_SAFE_NO_PAD, which rejects padding a JWT never carries.
        guard !payload.contains("=") else { return nil }
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = claims["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// A JSON array of strings exactly as serde_json's `to_string` writes it: no spaces, `/` not
    /// escaped (Foundation's JSONSerialization writes `\/`), non-ASCII left as UTF-8.
    public static func compactJSON(_ strings: [String]) -> String {
        "[" + strings.map(quoted).joined(separator: ",") + "]"
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// As agmux's `claude.rs` `text`: a value padded with whitespace or over 512 bytes is
    /// rejected, not trimmed, so both apps derive the same identity or none.
    private static func text(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= 512,
              s.trimmingCharacters(in: .whitespacesAndNewlines) == s else { return nil }
        return s
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
