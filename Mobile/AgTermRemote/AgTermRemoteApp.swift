import AgTermCore
import SwiftUI

@main
struct AgTermRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var remote = Remote()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if remote.pairing == nil && !remote.isDemo { PairView() } else { TabListView() }
            }
            .environmentObject(remote)
            .preferredColorScheme(.dark)
            .tint(Ink.accent)
            // The Camera app opens agterm-remote:// pairing links here.
            .onOpenURL { url in
                if let link = PairLink(url: url) { remote.pair(link) }
            }
            // Inactive (Control Center, the app switcher) keeps the connection; background drops it.
            .onChange(of: phase, initial: true) { _, phase in
                remote.setForeground(phase != .background)
            }
        }
    }
}

/// The privacy policy the App Store listing links to, also linked in the app.
let privacyPolicyURL = URL(string: "https://agterm.xanom.co/privacy")!
