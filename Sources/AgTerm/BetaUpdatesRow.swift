import AgTermCore
import SwiftUI

/// Settings → General → Updates: paste a beta key to get beta builds, or leave the beta.
struct BetaUpdatesRow: View {
    @ObservedObject var channel: BetaChannel
    /// Runs after a key is accepted; Settings checks for updates.
    var onJoin: () -> Void = {}
    @State private var draft = ""

    var body: some View {
        switch channel.status {
        case .on(let name):
            LabeledContent("Beta updates on (\(name))") {
                Button("Leave Beta") { channel.leave() }
            }
            Footnote("agterm installs beta builds as well as stable releases, whichever is newer. "
                     + "If you leave, you keep this version until a newer stable release comes out.")
        case .expired(let date):
            LabeledContent("Your beta key expired on \(date.formatted(date: .abbreviated, time: .omitted))") {
                Button("Leave Beta") { channel.leave() }
            }
            Footnote("agterm installs stable releases only. Paste a new key after leaving to get beta builds again.")
        case .off:
            LabeledContent("Beta updates") {
                HStack {
                    TextField("Beta key", text: $draft, prompt: Text("\(BetaKey.prefix)…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 240)
                        .onSubmit(join)
                    Button("Join Beta", action: join)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error = channel.joinError {
                Text(error)
                    .foregroundStyle(Color(nsColor: Theme.danger))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Footnote("Beta builds come out before stable releases and may have more bugs. Paste the key you were sent.")
            }
        }
    }

    private func join() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard channel.join(draft) else { return }
        draft = ""
        onJoin()
    }
}
