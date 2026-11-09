import AgTermCore
import Foundation
import Security

/// Settings → Macs, as stored: the Macs this one may run tasks on (their pairing codes) and,
/// when this Mac lets others run tasks here, its own secret. Secrets live in the Keychain; the
/// names of paired Macs also go in UserDefaults, so an agent's launch can tell whether to
/// mention `agterm-remote` without reading the Keychain. Any thread.
enum MacPairings {
    static let namesKey = "pairedMacNames"
    private static let service = (Bundle.main.bundleIdentifier ?? "agterm-dev") + ".macs"
    private static let pairedAccount = "paired"
    private static let workerAccount = "worker-secret"

    /// Paired Macs, in the order they were added; the first is the default.
    static var all: [MacPairing] {
        guard let data = read(pairedAccount) else { return [] }
        return (try? JSONDecoder().decode([MacPairing].self, from: data)) ?? []
    }

    static var names: [String] { UserDefaults.standard.stringArray(forKey: namesKey) ?? [] }

    /// Adds `pairing`, replacing a Mac with the same name.
    static func add(_ pairing: MacPairing) {
        save(all.filter { $0.name != pairing.name } + [pairing])
    }

    static func remove(named name: String) {
        save(all.filter { $0.name != name })
    }

    /// The named Mac, or the first when `name` is nil.
    static func find(_ name: String?) -> MacPairing? {
        let macs = all
        guard let name else { return macs.first }
        return macs.first { $0.name == name } ?? macs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func save(_ pairings: [MacPairing]) {
        if let data = try? JSONEncoder().encode(pairings) { write(data, to: pairedAccount) }
        UserDefaults.standard.set(pairings.map(\.name), forKey: namesKey)
    }

    // MARK: This Mac as a worker

    /// This Mac's secret, made the first time it's asked for.
    static var workerSecret: String {
        if let data = read(workerAccount), let secret = String(data: data, encoding: .utf8), secret.count == MacPairing.secretLength {
            return secret
        }
        return newWorkerSecret()
    }

    /// A new secret: every Mac paired with the old one has to be paired again.
    @discardableResult
    static func newWorkerSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "no random bytes")
        let secret = MacPairing.secret(from: bytes)
        write(Data(secret.utf8), to: workerAccount)
        return secret
    }

    // MARK: Keychain

    private static func read(_ account: String) -> Data? {
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, to account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { NSLog("agterm: couldn't save %@ in the Keychain (%d)", account, status) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
