#if DEBUG
import AgTermCore
import AppKit
import CryptoKit
import SwiftUI

extension SelfTest {
    /// The beta updates row: `AGTERM_BETA_CHECK=1 AGTERM_SELFTEST=<dir>`, plus `AGTERM_BETA_KEY=<key>`
    /// to check a key from scripts/beta-key.sh against the app's public key. Snapshots the row off,
    /// with a rejected key, on and expired, in light and dark, with keys from a throwaway signer
    /// and a private UserDefaults suite (the real setting is untouched).
    static func betaCheck(outDir: String) {
        if let text = ProcessInfo.processInfo.environment["AGTERM_BETA_KEY"] {
            let key = try? BetaKey(verifying: text, publicKey: BetaChannel.publicKey)
            print("selftest: beta: script's key accepted:", key != nil, key?.name ?? "")
        }
        let signer = Curve25519.Signing.PrivateKey()
        let suite = "agterm-selftest-beta-\(getpid())"
        guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
        var now = Date()
        let channel = BetaChannel(defaults: defaults, publicKey: signer.publicKey.rawRepresentation, now: { now })
        let row = Form { Section("Updates") { BetaUpdatesRow(channel: channel) } }
            .formStyle(.grouped).frame(width: 600).fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: row)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        func snap(_ name: String) {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                host.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/beta-\(name)-\(look).png"))
            }
        }
        func key(_ name: String, days: Int?) -> String {
            var payload: [String: Any] = ["name": name, "issued": Int(now.timeIntervalSince1970)]
            if let days { payload["expires"] = Int(now.timeIntervalSince1970) + days * 86_400 }
            let bytes = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            let signature = (try? signer.signature(for: bytes)) ?? Data()
            func url(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            return BetaKey.prefix + url(bytes) + "." + url(signature)
        }

        after(0.5) {
            print("selftest: beta: starts off:", channel.status == .off)
            snap("off")
            print("selftest: beta: rejects a pasted typo:", !channel.join(String(key("Ada", days: nil).dropLast(2))), channel.joinError ?? "")
            after(0.3) {
                snap("rejected")
                print("selftest: beta: joins with a valid key:", channel.join(key("Ada Lovelace", days: 30)), channel.status == .on(name: "Ada Lovelace"))
                print("selftest: beta: key kept in defaults:", defaults.string(forKey: BetaChannel.defaultsKey) != nil)
                after(0.3) {
                    snap("on")
                    now = now.addingTimeInterval(31 * 86_400)
                    channel.objectWillChange.send()
                    if case .expired = channel.status { print("selftest: beta: key expires: true") } else { print("selftest: beta: key expires: false") }
                    after(0.3) {
                        snap("expired")
                        channel.leave()
                        print("selftest: beta: leaves:", channel.status == .off && defaults.string(forKey: BetaChannel.defaultsKey) == nil)
                        UserDefaults.standard.removePersistentDomain(forName: suite)
                        exit(0)
                    }
                }
            }
        }
    }
}
#endif
