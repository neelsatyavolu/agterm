import AppKit
import Foundation
import Security

/// agterm's link to agmux Teams. agterm links as its own device (never reusing agmux's
/// credentials, which would make the two apps overwrite each other's hourly rows) through the same
/// device-link flow agmux uses: start → open the link page in the browser → poll until claimed.
@MainActor
final class TeamsAccount: ObservableObject {
    static let shared = TeamsAccount()
    nonisolated static let baseURL = URL(string: ProcessInfo.processInfo.environment["AGTERM_TEAMS_URL"] ?? "https://teams.agmux.dev")!

    enum State: Equatable {
        case signedOut
        /// Waiting for the user to finish in the browser.
        case linking(code: String, url: URL)
        case signedIn(name: String, email: String?)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var lastError: String?
    @Published var lastUpload: Date? {
        didSet { UserDefaults.standard.set(lastUpload, forKey: "teamsLastUpload") }
    }
    private var pollTask: Task<Void, Never>?

    private init() {
        lastUpload = UserDefaults.standard.object(forKey: "teamsLastUpload") as? Date
        if token != nil {
            state = .signedIn(name: UserDefaults.standard.string(forKey: "teamsUserName") ?? "Signed in",
                              email: UserDefaults.standard.string(forKey: "teamsUserEmail"))
        }
    }

    var isSignedIn: Bool { if case .signedIn = state { return true } else { return false } }

    // MARK: Device identity and token

    /// Stable per install, stored next to agterm's other state (not agmux's).
    var deviceID: String {
        let url = AgentIntegration.supportDir.appendingPathComponent("teams-device-id")
        if let id = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let id = "agterm-" + UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    private static let keychainService = (Bundle.main.bundleIdentifier ?? "agterm-dev") + ".teams"

    var token: String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func storeToken(_ token: String?) {
        SecItemDelete(keychainQuery() as CFDictionary)
        guard let token else { return }
        var item = keychainQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("agterm: couldn't save the Teams token to the keychain (%d)", status) }
    }

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.keychainService,
         kSecAttrAccount as String: "device-token"]
    }

    // MARK: Linking

    func startLinking() {
        lastError = nil
        pollTask?.cancel()
        pollTask = Task {
            do {
                let host = Host.current().localizedName ?? "Mac"
                let start: LinkStart = try await Self.post("/api/auth/device/start",
                                                           body: ["deviceId": deviceID, "label": "agterm on \(host)"])
                guard let url = URL(string: start.url) else { throw TeamsError.message("The link page address was invalid.") }
                state = .linking(code: start.code, url: url)
                NSWorkspace.shared.open(url)
                let deadline = Date().addingTimeInterval(Double(start.expiresInSeconds ?? 1800))
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let claim: LinkClaim = try await Self.post("/api/auth/device/claim", body: ["code": start.code])
                    if let token = claim.token, claim.pending != true {
                        storeToken(token)
                        let name = claim.user?.display_name ?? claim.user?.handle ?? "Signed in"
                        UserDefaults.standard.set(name, forKey: "teamsUserName")
                        UserDefaults.standard.set(claim.user?.email, forKey: "teamsUserEmail")
                        state = .signedIn(name: name, email: claim.user?.email)
                        TeamsSync.shared.syncSoon()
                        return
                    }
                }
                if !Task.isCancelled { throw TeamsError.message("The link expired. Try again.") }
            } catch is CancellationError {
            } catch {
                state = .signedOut
                lastError = error.localizedDescription
            }
        }
    }

    func cancelLinking() {
        pollTask?.cancel()
        pollTask = nil
        if case .linking = state { state = .signedOut }
    }

    func signOut() {
        pollTask?.cancel()
        // Team logins go back while the token can still return them.
        TeamAccounts.shared.giveBackAll()
        storeToken(nil)
        UserDefaults.standard.removeObject(forKey: "teamsUserName")
        UserDefaults.standard.removeObject(forKey: "teamsUserEmail")
        lastUpload = nil
        state = .signedOut
    }

    /// The server rejected the token (revoked on the web): forget it.
    func tokenRejected() {
        signOut()
        lastError = "agmux Teams signed this Mac out. Sign in again to keep reporting."
    }

    // MARK: HTTP

    private struct LinkStart: Decodable { let code: String; let url: String; let expiresInSeconds: Int? }
    private struct LinkClaim: Decodable {
        struct User: Decodable { let display_name: String?; let email: String?; let handle: String? }
        let pending: Bool?
        let token: String?
        let user: User?
    }
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let data: T?; let error: String? }

    enum TeamsError: LocalizedError {
        case message(String)
        case unauthorized
        var errorDescription: String? {
            switch self {
            case .message(let m): m
            case .unauthorized: "agmux Teams no longer accepts this Mac's sign-in."
            }
        }
    }

    /// POSTs JSON and unwraps the service's `{ok, data, error}` envelope.
    static func post<T: Decodable>(_ path: String, body: Any, token: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("agterm", forHTTPHeaderField: "X-Client")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw TeamsError.unauthorized }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw TeamsError.message("Unexpected reply from agmux Teams (HTTP \(status)).")
        }
        guard envelope.ok, let value = envelope.data else {
            throw TeamsError.message(envelope.error ?? "agmux Teams refused the request (HTTP \(status)).")
        }
        return value
    }
}
