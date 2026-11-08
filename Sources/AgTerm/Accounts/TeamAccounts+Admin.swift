import AgTermCore
import Foundation

/// Renaming, pausing and removing the team's pooled logins, from the Teams window. The service
/// decides who may: the team's owner for any login, a manager for the ones they added.
extension TeamAccounts {
    func rename(_ account: TeamPool.Account, to label: String, completion: @escaping (TeamPool.Failure?) -> Void) {
        guard let body = TeamPool.renameBody(label) else {
            return completion(TeamPool.Failure(message: "Names are 1 to 120 characters, with no control characters.", retryable: false))
        }
        change(account, "PATCH", body: body, completion: completion) { status, reply in
            _ = try TeamPool.changed(status: status, body: reply, team: Self.team(of: account))
        }
    }

    /// A paused login stays in the pool but isn't lent out; loans already out run until returned.
    func setPaused(_ account: TeamPool.Account, _ paused: Bool, completion: @escaping (TeamPool.Failure?) -> Void) {
        change(account, "PATCH", body: TeamPool.pauseBody(paused: paused), completion: completion) { status, reply in
            _ = try TeamPool.changed(status: status, body: reply, team: Self.team(of: account))
        }
    }

    /// Deletes the login and its tokens from the team.
    func remove(_ account: TeamPool.Account, completion: @escaping (TeamPool.Failure?) -> Void) {
        change(account, "DELETE", body: nil, completion: completion) { status, reply in
            try TeamPool.removed(status: status, body: reply)
        }
    }

    private static func team(of account: TeamPool.Account) -> TeamPool.Team {
        TeamPool.Team(id: account.teamID, name: account.teamName)
    }

    /// One request, then the list again so every view shows the change. `completion` runs on the main queue.
    private func change(_ account: TeamPool.Account, _ method: String, body: [String: Any]?,
                        completion: @escaping (TeamPool.Failure?) -> Void,
                        parse: @escaping @Sendable (Int, Data) throws -> Void) {
        guard let token else {
            return completion(TeamPool.Failure(message: "agterm is signed out of agmux Teams.", retryable: false))
        }
        let path = ["api", "teams", account.teamID, "provider-accounts", account.id]
        let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        Task {
            var failure: TeamPool.Failure?
            do {
                let object = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let (status, reply) = try await Self.send(token, method, path, body: object)
                try parse(status, reply)
            } catch {
                failure = error as? TeamPool.Failure ?? TeamPool.networkError
            }
            await MainActor.run { [failure] in
                completion(failure)
                self.refresh()
            }
        }
    }
}
