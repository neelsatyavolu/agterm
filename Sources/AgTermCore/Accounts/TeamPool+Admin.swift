import Foundation

/// Renaming, pausing and removing pooled logins (`PATCH` and `DELETE …/provider-accounts/:id`).
/// The service lets the team's owner change any login, and a manager only the ones they added.
extension TeamPool {
    public static let notManageable = Failure(
        message: "This login is gone, or only the team's owner or the manager who added it can change it.", retryable: false)

    /// `{label}`, or nil when the name is empty, over 120 characters or has control characters.
    public static func renameBody(_ label: String) -> [String: Any]? {
        text(label, max: 120).map { ["label": $0] }
    }

    /// A paused login stays in the pool but isn't lent to anyone.
    public static func pauseBody(paused: Bool) -> [String: Any] {
        ["enabled": !paused]
    }

    /// The reply to a rename or pause: the login as it is now.
    public static func changed(status: Int, body: Data, team: Team) throws -> Account {
        try check(status)
        guard let row = try data(body)["account"] as? [String: Any], let account = account(row, team: team) else { throw invalidResponse }
        return account
    }

    /// The reply to a removal.
    public static func removed(status: Int, body: Data) throws {
        try check(status)
        guard try data(body)["deleted"] as? Bool == true else { throw invalidResponse }
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 403, 404: throw notManageable
        default: throw failure(status: status)
        }
    }
}
