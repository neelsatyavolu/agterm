import SwiftUI

/// Settings → Cloud → 1Password: a service account token for op on the cloud machine, where the
/// Mac's 1Password app and Touch ID aren't. It goes straight to the machine
/// (`CloudSync.writeOpToken`); this Mac keeps only whether one was saved.
struct CloudOnePasswordSection: View {
    static let savedKey = "cloudOpTokenSaved"

    @AppStorage(Self.savedKey) private var saved = false
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            if saved {
                LabeledContent("Service account token saved on the machine") {
                    Button("Remove") { save(nil) }.disabled(busy)
                }
            } else {
                LabeledContent("Service account token") {
                    HStack {
                        SecureField("ops_…", text: $token).labelsHidden().frame(width: 220)
                        Button("Save to Machine") { save(trimmed) }.disabled(busy || !trimmed.hasPrefix("ops_"))
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("1Password")
        } footer: {
            Footnote("Lets agents in cloud tabs use the 1Password CLI. Make a service account in 1Password's developer settings, give it the vaults agents need (service accounts can't read your Personal vault), and paste its token here. It's saved only on your cloud machine, readable only by you, and new cloud tabs get it as OP_SERVICE_ACCOUNT_TOKEN.")
        }
    }

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ value: String?) {
        guard let cloud = CloudHost.configured else {
            error = "Set up the cloud machine first."
            return
        }
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String?
            do {
                try CloudSync.writeOpToken(value, to: cloud)
                failure = nil
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                busy = false
                if let failure {
                    error = "Couldn't reach the cloud machine: \(failure)"
                } else {
                    saved = value != nil
                    token = ""
                }
            }
        }
    }
}
