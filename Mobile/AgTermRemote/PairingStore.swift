import Foundation
import Security

/// The paired Mac: which hub to dial and this phone's bearer token for it.
struct Pairing: Codable, Equatable {
    var desktopId: String
    var phoneToken: String
    var deviceId: String?
    var relay: String
}

/// Keeps the pairing in the Keychain, so clearing app data or reinstalling from a backup
/// doesn't silently leave a token lying around in plain files.
enum PairingStore {
    private static let service = "co.xanom.agterm.remote"
    private static let current = "pairing"
    /// A Mac forgotten before the relay heard push.unregister; kept only until it does.
    private static let forgotten = "forgotten-pairing"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Pairing? { load(current) }
    @discardableResult static func save(_ pairing: Pairing) -> Bool { save(pairing, as: current) }
    static func clear() { SecItemDelete(query(current) as CFDictionary) }

    static func loadForgotten() -> Pairing? { load(forgotten) }
    static func saveForgotten(_ pairing: Pairing) { save(pairing, as: forgotten) }
    static func clearForgotten() { SecItemDelete(query(forgotten) as CFDictionary) }

    private static func load(_ account: String) -> Pairing? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    @discardableResult
    private static func save(_ pairing: Pairing, as account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = data
        // Reconnecting after the phone restarts must work before the first unlock is long past.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("agterm Remote: Keychain save failed: %d", status) }
        return status == errSecSuccess
    }
}
