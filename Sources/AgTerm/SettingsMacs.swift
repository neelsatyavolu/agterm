import AgTermCore
import AppKit
import SwiftUI

/// Settings → Macs: let your other Macs run tasks on this one, and pick the Macs this one's
/// agents can send tasks to with `agterm-remote`.
struct MacsPane: View {
    @State private var workerOn = MacWorker.isEnabled
    @State private var paired = MacPairings.all
    @State private var code = ""
    @State private var addError: String?
    @State private var copied = false
    @State private var confirmingNewCode = false
    /// What the last check found for each Mac: nil while checking, "" when it answered.
    @State private var checks: [String: String?] = [:]

    var body: some View {
        Form {
            Section {
                Toggle("Let my other Macs run tasks on this Mac", isOn: $workerOn)
                    .onChange(of: workerOn) { _, on in MacWorker.setEnabled(on) }
                if workerOn {
                    LabeledContent("Pairing code") {
                        HStack {
                            Button(copied ? "Copied" : "Copy Pairing Code") { copyCode() }
                            Button("New Code…") { confirmingNewCode = true }
                        }
                    }
                    LabeledContent("Shown to other Macs as", value: MacWorker.computerName)
                }
            } header: {
                Text("This Mac")
            } footer: {
                Footnote("Paired Macs can run commands here as you, in a copy of their project under ~/\(MacTask.tasksFolder), even while agterm is closed. Treat the pairing code like a password. A new code unpairs every Mac that has the old one.")
            }
            .confirmationDialog("Make a new pairing code?", isPresented: $confirmingNewCode) {
                Button("New Code", role: .destructive) {
                    MacWorker.newCode()
                    copied = false
                }
            } message: {
                Text("Macs paired with the old code can't run tasks here until you add the new one on them. Tasks running now are stopped.")
            }

            Section {
                ForEach(paired, id: \.name) { mac in row(mac) }
                LabeledContent {
                    Button("Add") { add() }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } label: {
                    TextField("Paste a pairing code", text: $code).onSubmit(add)
                }
                if let addError {
                    Text(addError).foregroundStyle(.red)
                }
            } header: {
                Text("Macs this Mac can use")
            } footer: {
                Footnote("Agents in agterm tabs are told about these Macs and run heavy commands there with agterm-remote run -- <command>, which copies the repo over (git-ignored files stay here), runs the command there and shows its output in the tab. You can use it too. The first Mac is the default. Get a code from the other Mac's Settings → Macs.")
            }
        }
        .onAppear { paired = MacPairings.all }
    }

    private func row(_ mac: MacPairing) -> some View {
        LabeledContent {
            HStack {
                Button("Check") { check(mac) }.disabled(checks[mac.name] == .some(nil))
                Button("Remove") {
                    MacPairings.remove(named: mac.name)
                    paired = MacPairings.all
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                Text(status(mac)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ mac: MacPairing) -> String {
        switch checks[mac.name] {
        case .none: return "\(mac.host):\(mac.port)"
        case .some(.none): return "Checking…"
        case .some(.some(let problem)): return problem.isEmpty ? "Ready" : "Not reachable: \(problem)"
        }
    }

    private func check(_ mac: MacPairing) {
        checks[mac.name] = .some(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = MacHost(mac).check() ?? ""
            DispatchQueue.main.async { checks[mac.name] = .some(problem) }
        }
    }

    private func add() {
        guard let pairing = MacPairing(code: code) else {
            addError = "That isn't a pairing code. Copy it from the other Mac's Settings → Macs."
            return
        }
        MacPairings.add(pairing)
        paired = MacPairings.all
        code = ""
        addError = nil
        check(pairing)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MacWorker.pairing.code, forType: .string)
        copied = true
    }
}
