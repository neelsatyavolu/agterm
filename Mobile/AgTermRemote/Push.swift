import SwiftUI
import UIKit
import UserNotifications

/// Notifications while the app is closed: the relay pushes "needs you" and "finished" alerts to
/// the token registered here, under this app's bundle id. Tapping one opens its tab.
@MainActor
final class Push: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Push()

    /// The APNs device token, hex, once iOS hands it over.
    private(set) var token: String?
    var onToken: ((String) -> Void)?
    /// A tapped notification's tab id.
    var onOpen: ((String) -> Void)?
    /// A tab tapped before anyone listened (the app was launched by the tap).
    private var pendingOpen: String?

    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            // Already allowed: get a fresh token at every launch, as Apple recommends.
            if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Asks once (iOS remembers the answer), then registers for a token.
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func received(token data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        token = hex
        onToken?(hex)
    }

    func listenForOpens(_ open: @escaping (String) -> Void) {
        onOpen = open
        if let pending = pendingOpen {
            pendingOpen = nil
            open(pending)
        }
    }

    // Completion-handler forms, finished on the main queue: the async forms complete off it,
    // and UIKit aborts on that.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = response.notification.request.content.userInfo["threadId"] as? String
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let tab { if let onOpen = self.onOpen { onOpen(tab) } else { self.pendingOpen = tab } }
            }
            done()
        }
    }

    /// The relay doesn't push to a phone with the app open, so anything shown here is a leftover.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async { done([]) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch ends, so a tap that launched the app still reaches the delegate.
        Push.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("agterm Remote: no push token: %@", error.localizedDescription)
    }
}
