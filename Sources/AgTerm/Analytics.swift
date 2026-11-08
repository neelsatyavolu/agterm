import AgTermCore
import Foundation

/// Anonymous usage counts, sent to agmux's analytics service (`AnalyticsClient.baseURL`).
/// On unless turned off in Settings → General, as in agmux. Debug builds, unbundled builds,
/// self-tests and runs with AGTERM_STATE_DIR never send. Requests run on URLSession's own
/// queue; one that fails is dropped, never retried.
enum Analytics {
    static let enabledKey = "analyticsEnabled"
    private static let installIDKey = "analyticsInstallID"
    private static let lastVersionKey = "analyticsLastVersion"

    /// What Settings shows under the switch: everything that is sent, and what never is.
    static let disclosure = "Sends a random ID made on this Mac, agterm's version, the macOS version and the Mac's "
        + "processor type, which agents start in your tabs (such as Claude Code or Codex), and how often you split "
        + "a tab, open the command bar, open a cloud tab, pair a phone or install an update. It never sends your "
        + "files, folders, commands, anything you type, repository names or account details."

    static var isOptedIn: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return Bundle.main.bundleIdentifier != nil
        #endif
    }

    private static func allowsSending(optedIn: Bool = isOptedIn) -> Bool {
        AnalyticsGate.allowsSending(optedIn: optedIn, isReleaseBuild: isReleaseBuild,
                                    environment: ProcessInfo.processInfo.environment)
    }

    private static let client: AnalyticsClient = {
        let id = AnalyticsInstallID.resolve(stored: UserDefaults.standard.string(forKey: installIDKey))
        UserDefaults.standard.set(id, forKey: installIDKey)
        return AnalyticsClient(installID: id, isAllowed: { allowsSending() }, transport: { post(path: $0, body: $1, done: $2) })
    }()

    private static var timer: DispatchSourceTimer?

    /// At launch: the heartbeat, an installed update, and a flush every few minutes.
    static func start() {
        // Opting in later still needs the timer, so only the build and environment are checked here.
        guard allowsSending(optedIn: true) else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let previous = UserDefaults.standard.string(forKey: lastVersionKey)
        UserDefaults.standard.set(version, forKey: lastVersionKey)
        client.sendHeartbeat(AnalyticsHeartbeat(appVersion: version, osVersion: osVersion, arch: arch))
        client.record(.updateInstalled(previous: previous, current: version))

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + AnalyticsClient.flushInterval, repeating: AnalyticsClient.flushInterval, leeway: .seconds(30))
        timer.setEventHandler { client.flush() }
        timer.resume()
        self.timer = timer
    }

    static func record(_ event: AnalyticsEvent?) {
        guard event != nil, allowsSending() else { return }
        client.record(event)
    }

    /// At quit: sends what's queued, waiting at most a second so quitting never hangs.
    static func flushAtQuit() {
        guard allowsSending(), client.queuedCount > 0 else { return }
        let sent = DispatchSemaphore(value: 0)
        guard client.flush(done: { sent.signal() }) else { return }
        _ = sent.wait(timeout: .now() + 1)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func post(path: String, body: Data, done: @escaping @Sendable () -> Void) {
        guard let url = URL(string: path, relativeTo: AnalyticsClient.baseURL) else { return done() }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { _, _, _ in done() }.resume()
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
