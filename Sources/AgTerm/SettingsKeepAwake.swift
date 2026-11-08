import AgTermCore
import SwiftUI

/// Settings → Agents → Sleep: keep the Mac awake while agents work, optionally with the lid closed.
struct KeepAwakeSection: View {
    @AppStorage(KeepAwake.enabledKey) private var enabled = false
    @AppStorage(KeepAwake.closedLidKey) private var closedLid = false
    @State private var installed = KeepAwake.shared.helperInstalled
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Keep Mac awake while agents run", isOn: $enabled)
            Toggle("Also when the lid is closed", isOn: Binding(get: { closedLid && installed }, set: setClosedLid))
                .disabled(!enabled || working)
            if installed {
                Button("Remove Closed-Lid Helper…", action: uninstall).disabled(working)
            }
            if let message, !message.isEmpty {
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("Sleep")
        } footer: {
            Footnote("While an agent tab on this Mac is working, the Mac doesn't go to sleep on its own. It can "
                     + "still sleep when you close the lid, unless you also turn on the lid option, which asks for "
                     + "an administrator's password once to install a small helper (\(ClosedLidHelper.path)). "
                     + "It lets the Mac sleep again as soon as no agent is working, or if agterm quits or crashes.\n\n"
                     + "With the lid closed, a Mac in a bag can get hot, and on battery it keeps draining until the "
                     + "agents finish. agterm shows a notification when that starts on battery.")
        }
        .onReceive(NotificationCenter.default.publisher(for: KeepAwake.helperChanged)) { _ in
            installed = KeepAwake.shared.helperInstalled
        }
        .onAppear { KeepAwake.shared.recheckHelper() }
    }

    private func setClosedLid(_ on: Bool) {
        message = nil
        guard on, !installed else {
            closedLid = on
            return
        }
        working = true
        KeepAwake.shared.installHelper { error in
            working = false
            installed = KeepAwake.shared.helperInstalled
            message = error
            if error == nil { closedLid = true }
        }
    }

    private func uninstall() {
        message = nil
        working = true
        KeepAwake.shared.uninstallHelper { error in
            working = false
            installed = KeepAwake.shared.helperInstalled
            if error == nil { closedLid = false }
            message = error
        }
    }
}
