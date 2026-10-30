import AppKit
import SwiftUI

/// Settings → Cloud: the agterm Cloud plan, its hours, and the machine tabs move to.
struct CloudPane: View {
    @ObservedObject var account: CloudAccount
    @ObservedObject var teams: TeamsAccount
    @State private var limit = ""

    var body: some View {
        Form {
            Section {
                if !teams.isSignedIn {
                    LabeledContent("Sign in to agmux Teams to use agterm Cloud") {
                        Button("Open Teams & Phone") { SettingsWindowController.shared.show(pane: "Teams & Phone") }
                    }
                } else if let status = account.status {
                    plan(status)
                    if status.plan == "active" { machine(status) }
                } else {
                    LabeledContent(account.busy ? "Checking…" : "Couldn't check your plan") {
                        Button("Check Again") { account.refresh() }.disabled(account.busy)
                    }
                }
                if let error = account.lastError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("agterm Cloud")
            } footer: {
                Footnote("Your tabs keep running on a cloud machine while this Mac is off. Shell → Move All Tabs to Cloud copies each tab's folder and conversation there and continues it. $12 a month for 100 hours, 20 GB and 4 GB of memory. Agents sign in there once; your Mac's logins are never copied.")
            }
        }
        .onAppear { if teams.isSignedIn { account.refresh() } }
    }

    @ViewBuilder
    private func plan(_ status: CloudAccount.Status) -> some View {
        switch status.plan {
        case "active":
            LabeledContent("Plan", value: "Active")
            LabeledContent("This month", value: String(format: "%.1f of %.0f hours", status.hoursUsed, status.hoursLimit))
            if status.capped {
                Text("The hours are used up, so the machine is stopped until next month.").foregroundStyle(.secondary)
            }
            LabeledContent("Stop the machine after") {
                HStack {
                    TextField("hours", text: $limit, prompt: Text(String(format: "%.0f", status.hoursLimit)))
                        .frame(width: 60)
                        .onSubmit { account.setLimit(limit.isEmpty ? nil : Double(limit)) }
                    Text("hours a month")
                }
            }
            LabeledContent("Billing") { Button("Manage…") { account.manageBilling() } }
        case "past_due":
            LabeledContent("The last payment didn't go through") { Button("Update Payment…") { account.manageBilling() } }
        default:
            LabeledContent(status.plan == "canceled" ? "Ended" : "Not subscribed") {
                Button("Subscribe…") { account.subscribe() }.disabled(account.busy)
            }
        }
    }

    @ViewBuilder
    private func machine(_ status: CloudAccount.Status) -> some View {
        if let machine = status.machine, CloudCredentials.current != nil {
            LabeledContent("Machine", value: [machine.state.map(Self.describe), machine.region].compactMap { $0 }.joined(separator: " · "))
        } else {
            LabeledContent("No machine yet") {
                Button("Set Up Machine") { account.setUpMachine() }.disabled(account.busy)
            }
        }
    }

    /// Fly's machine states, said plainly.
    private static func describe(_ state: String) -> String {
        switch state {
        case "started": "Running"
        case "stopped", "suspended": "Asleep, starts when you connect"
        case "created": "Ready"
        default: state.capitalized
        }
    }
}
