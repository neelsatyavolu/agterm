import AppKit
import Sparkle

/// Sparkle auto-updates. The feed is the appcast attached to the latest GitHub release
/// (SUFeedURL in Info.plist), or with a beta key the beta feed (AGTermBetaFeedURL); each update
/// must carry an EdDSA signature matching SUPublicEDKey, on top of the Developer ID signature.
final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    /// Sparkle keeps its delegate weakly.
    private let delegate = UpdaterDelegate()

    override private init() {
        // A build without a feed (e.g. `swift run`) has nothing to update from.
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        let delegate = delegate
        controller = hasFeed
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
            : nil
        super.init()
    }

    var isAvailable: Bool { controller != nil }

    /// Set once Sparkle is about to quit agterm to install an update and open it again. Stays
    /// set if that quit is cancelled: Sparkle still relaunches after the next one.
    var isRelaunchingForUpdate: Bool { delegate.relaunching }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private(set) var relaunching = false

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        relaunching = true
    }

    /// Asked before each check; nil means SUFeedURL.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard BetaChannel.shared.isOn else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "AGTermBetaFeedURL") as? String
    }
}
