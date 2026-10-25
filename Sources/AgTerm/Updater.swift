import AppKit
import Sparkle

/// Sparkle auto-updates. The feed is the appcast attached to the latest GitHub release
/// (SUFeedURL in Info.plist); each update must carry an EdDSA signature matching
/// SUPublicEDKey, on top of the Developer ID signature.
final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    override private init() {
        // A build without a feed (e.g. `swift run`) has nothing to update from.
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = hasFeed
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        super.init()
    }

    var isAvailable: Bool { controller != nil }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
