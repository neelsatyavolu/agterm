import AppKit
import Foundation
import Security

/// agterm Cloud (docs/cloud-sessions-plan.md): the subscription and the cloud machine, through the
/// control plane (cloud/control), with the agmux account. Signing in here links its own device
/// through agmux's device-link page and shares nothing; a Mac already signed in to agmux Teams
/// uses that sign-in. Setting the machine up stores how to reach it (`CloudCredentials`), which
/// `CloudHost.configured` then uses.
@MainActor
final class CloudAccount: ObservableObject {
    static let shared = CloudAccount()
    /// Hidden until the service launches: shown with `defaults write <bundle id> agtermCloud -bool
    /// true`, or in development with `AGTERM_CLOUD` or `AGTERM_CLOUD_CONTROL` set.
    nonisolated static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["AGTERM_CLOUD"] != nil || env["AGTERM_CLOUD_CONTROL"] != nil || UserDefaults.standard.bool(forKey: "agtermCloud")
    }

    nonisolated static let controlURL = URL(string: ProcessInfo.processInfo.environment["AGTERM_CLOUD_CONTROL"] ?? "https://cloud.agterm.xanom.co")!

    struct Status: Decodable, Equatable {
        struct Machine: Decodable, Equatable {
            let id: String
            let state: String?
            let region: String?
        }

        /// none, active, past_due or canceled.
        let plan: String
        let hoursUsed: Double
        let hoursLimit: Double
        /// Hours the plan includes; hours past them up to the limit cost $0.10 each.
        let hoursIncluded: Double?
        let hoursMax: Double?
        let capped: Bool
        let machine: Machine?
    }

    enum SignIn: Equatable {
        case signedOut
        /// Waiting for the user to approve in the browser.
        case linking(URL)
        case signedIn(email: String?)
    }

    @Published private(set) var status: Status?
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    @Published private(set) var signIn: SignIn = .signedOut
    private var linkTask: Task<Void, Never>?

    private init() {
        if CloudCredentials.deviceToken != nil { signIn = .signedIn(email: UserDefaults.standard.string(forKey: "cloudEmail")) }
    }

    /// The token the control plane takes: this sign-in's, else agmux Teams'.
    var token: String? { CloudCredentials.deviceToken ?? TeamsAccount.shared.token }

    var isSignedIn: Bool { token != nil }

    // MARK: Signing in

    private struct LinkStart: Decodable { let code: String; let url: String; let expiresInSeconds: Int? }
    private struct LinkClaim: Decodable {
        struct User: Decodable { let email: String? }
        let pending: Bool?
        let token: String?
        let user: User?
    }

    func startSignIn() {
        lastError = nil
        linkTask?.cancel()
        linkTask = Task {
            do {
                let host = Host.current().localizedName ?? "Mac"
                let start: LinkStart = try await TeamsAccount.post("/api/auth/device/start",
                                                                   body: ["deviceId": CloudCredentials.deviceID, "label": "agterm Cloud on \(host)"])
                guard let url = URL(string: start.url) else { throw Failure(message: "The sign-in page address was invalid.") }
                signIn = .linking(url)
                NSWorkspace.shared.open(url)
                let deadline = Date().addingTimeInterval(Double(start.expiresInSeconds ?? 1800))
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let claim: LinkClaim = try await TeamsAccount.post("/api/auth/device/claim", body: ["code": start.code])
                    if let token = claim.token, claim.pending != true {
                        CloudCredentials.saveDeviceToken(token)
                        UserDefaults.standard.set(claim.user?.email, forKey: "cloudEmail")
                        signIn = .signedIn(email: claim.user?.email)
                        refresh()
                        return
                    }
                }
                if !Task.isCancelled { throw Failure(message: "The sign-in link expired. Try again.") }
            } catch is CancellationError {
            } catch {
                signIn = .signedOut
                lastError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        linkTask?.cancel()
        if case .linking = signIn { signIn = .signedOut }
    }

    /// Forgets this sign-in; the machine and its tabs stay.
    func signOut() {
        CloudCredentials.saveDeviceToken(nil)
        UserDefaults.standard.removeObject(forKey: "cloudEmail")
        signIn = .signedOut
        status = nil
    }

    func refresh() {
        run { try await self.request("GET", "/v1/cloud") as Status } then: { self.status = $0 }
    }

    /// Opens Stripe Checkout in the browser; the plan turns active once it's paid.
    func subscribe() {
        run { try await self.request("POST", "/v1/cloud/checkout") as Link } then: { NSWorkspace.shared.open($0.url) }
    }

    func manageBilling() {
        run { try await self.request("POST", "/v1/cloud/portal") as Link } then: { NSWorkspace.shared.open($0.url) }
    }

    /// Makes the machine on first use, with this Mac's user name and home folder (paths are the
    /// same there), and keeps what it takes to connect once it is running: a new machine takes
    /// about 20 seconds to boot, and a tab opened before then would fail.
    func setUpMachine() {
        let body = ["user": NSUserName(), "home": NSHomeDirectory()]
        run {
            let connection: CloudCredentials.Connection = try await self.request("POST", "/v1/cloud/machine", body: body)
            var status: Status = try await self.request("GET", "/v1/cloud")
            for _ in 0..<30 where status.machine?.state != "started" {
                try await Task.sleep(for: .seconds(2))
                status = try await self.request("GET", "/v1/cloud")
            }
            return (connection, status)
        } then: { connection, status in
            CloudCredentials.save(connection)
            self.status = status
        }
    }

    /// Hours a month after which the machine stops; nil for all the included hours.
    func setLimit(_ hours: Double?) {
        run { try await self.request("POST", "/v1/cloud/cap", body: ["hours": hours]) as Status } then: { self.status = $0 }
    }

    // MARK: Requests

    private struct Link: Decodable { let url: URL }

    private struct Failure: Decodable, Error, LocalizedError {
        let message: String?
        var errorDescription: String? { message ?? "The cloud service didn't answer." }
    }

    private func run<T>(_ work: @escaping () async throws -> T, then done: @escaping (T) -> Void) {
        busy = true
        lastError = nil
        Task {
            do {
                let value = try await work()
                done(value)
            } catch {
                lastError = error.localizedDescription
            }
            busy = false
        }
    }

    private func request<T: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body? = nil as [String: String]?) async throws -> T {
        guard let token else { throw Failure(message: "Sign in to agterm Cloud first.") }
        var request = URLRequest(url: Self.controlURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw (try? JSONDecoder().decode(Failure.self, from: data)) ?? Failure(message: nil)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// How to reach the cloud machine, in the Keychain. Read once and cached; any thread.
enum CloudCredentials {
    struct Connection: Codable, Equatable {
        let url: URL
        let machine: String?
        let token: String
    }

    private static let service = (Bundle.main.bundleIdentifier ?? "agterm-dev") + ".cloud"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: Connection??

    static var current: Connection? {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = load()
        cache = .some(loaded)
        return loaded
    }

    static func save(_ connection: Connection) {
        guard let data = try? JSONEncoder().encode(connection) else { return }
        SecItemDelete(query() as CFDictionary)
        var add = query()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        lock.lock()
        cache = .some(connection)
        lock.unlock()
    }

    private static func load() -> Connection? {
        var search = query()
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }

    private static func query(_ account: String = "machine") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    // MARK: Sign-in

    /// agterm Cloud's own device token from agmux's device link; nil if signed in another way.
    static var deviceToken: String? {
        var search = query("device-token")
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveDeviceToken(_ token: String?) {
        SecItemDelete(query("device-token") as CFDictionary)
        guard let token else { return }
        var add = query("device-token")
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Stable per install, apart from agmux Teams' own device.
    static var deviceID: String {
        let key = "cloudDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "agterm-cloud-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
