import AgTermCore
import Foundation

/// Beta updates. A tester pastes a beta key from scripts/beta-key.sh; while it is valid, Updater
/// reads the beta feed, which lists the newest beta and the newest stable build. The key is kept
/// in UserDefaults: it isn't secret, only signed.
final class BetaChannel: ObservableObject {
    static let shared = BetaChannel(defaults: .standard)
    static let defaultsKey = "betaKey"
    /// Public half of the Ed25519 key that signs beta keys (private half: 1Password
    /// "agterm Beta Key Signing Key", Private vault).
    static let publicKey = Data(base64Encoded: "pY7tSOVznodsLQ9cc3UP6OAyp1R8g+XX+BWd0RsA5WY=")!

    enum Status: Equatable {
        case off
        case on(name: String)
        case expired(Date)
    }

    private let defaults: UserDefaults
    private let publicKey: Data
    private let now: () -> Date
    @Published private(set) var storedKey: String?
    /// Why the last pasted key was turned down, shown under the field.
    @Published private(set) var joinError: String?

    init(defaults: UserDefaults, publicKey: Data = BetaChannel.publicKey, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.publicKey = publicKey
        self.now = now
        storedKey = defaults.string(forKey: Self.defaultsKey)
    }

    /// Checked each time, so a key that expires turns beta updates off.
    var status: Status {
        guard let storedKey else { return .off }
        do {
            return .on(name: try BetaKey(verifying: storedKey, publicKey: publicKey, now: now()).name)
        } catch BetaKey.Problem.expired(let date) {
            return .expired(date)
        } catch {
            return .off
        }
    }

    var isOn: Bool {
        if case .on = status { return true }
        return false
    }

    /// Keeps a valid key, or sets `joinError` to why it was turned down.
    @discardableResult
    func join(_ text: String) -> Bool {
        do {
            _ = try BetaKey(verifying: text, publicKey: publicKey, now: now())
        } catch BetaKey.Problem.expired(let date) {
            joinError = "This key expired on \(date.formatted(date: .abbreviated, time: .omitted)). Ask for a new one."
            return false
        } catch BetaKey.Problem.badSignature {
            joinError = "This key isn't valid. Check that you copied all of it."
            return false
        } catch {
            joinError = "That isn't a beta key. Beta keys start with \(BetaKey.prefix)."
            return false
        }
        let compact = text.filter { !$0.isWhitespace }
        defaults.set(compact, forKey: Self.defaultsKey)
        storedKey = compact
        joinError = nil
        return true
    }

    func leave() {
        defaults.removeObject(forKey: Self.defaultsKey)
        storedKey = nil
        joinError = nil
    }
}
