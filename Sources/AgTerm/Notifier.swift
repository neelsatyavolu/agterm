import AgTermCore
import AppKit
import UserNotifications

/// macOS notifications and a sound when an agent finishes or needs you, like agmux.
/// Only for tabs you aren't looking at; clicking one brings agterm forward on that tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static let completeKey = "notifyComplete"
    static let attentionKey = "notifyAttention"
    static let soundKey = "notifySound"
    private static let soundFile = "agterm-notify.wav"

    /// Called with the tab id when a notification is clicked.
    var onOpen: ((String) -> Void)?

    /// UserNotifications needs a bundled app; `swift run` builds get no notifications.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    private var authorized: Bool?
    private lazy var fallbackSound = NSSound(named: Self.soundFile)
        ?? Bundle.main.url(forResource: "agterm-notify", withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: true) }

    func start() {
        center?.delegate = self
    }

    func post(status: TabStatus, tabID: String, topic: String, folder: String) {
        let defaults = UserDefaults.standard
        let body: String
        switch status {
        case .waiting where defaults.object(forKey: Self.attentionKey) as? Bool ?? true: body = "Needs your attention"
        case .done where defaults.object(forKey: Self.completeKey) as? Bool ?? true: body = "Finished"
        default: return
        }
        let wantSound = defaults.object(forKey: Self.soundKey) as? Bool ?? true
        guard let center else {
            if wantSound { fallbackSound?.play() }
            return
        }
        withPermission(center) { granted in
            guard granted else {
                if wantSound { self.fallbackSound?.play() }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = topic
            content.subtitle = folder
            content.body = body
            content.threadIdentifier = tabID
            content.userInfo = ["tabID": tabID]
            if wantSound { content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.soundFile)) }
            center.add(UNNotificationRequest(identifier: "\(tabID).\(status.label)", content: content, trigger: nil))
        }
    }

    private func withPermission(_ center: UNUserNotificationCenter, _ done: @escaping (Bool) -> Void) {
        if let authorized { return done(authorized) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("agterm: notification permission: %@", error.localizedDescription) }
            DispatchQueue.main.async {
                self.authorized = granted
                done(granted)
            }
        }
    }

    // Show banners even while agterm is frontmost: the tab they're about is in the background.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tabID = response.notification.request.content.userInfo["tabID"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.onOpen?(tabID)
            }
        }
        completionHandler()
    }
}
