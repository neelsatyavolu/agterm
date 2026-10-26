import AgTermCore
import AppKit
import CoreImage
import SwiftUI

/// agmux Teams: link this Mac, see what is shared, sign out.
struct TeamsSection: View {
    @ObservedObject var account: TeamsAccount
    @State private var confirming = false

    static let shared = [
        "Hourly totals from Claude Code and Codex sessions started in agterm: tokens, estimated cost, active time",
        "Session, turn and tool-call counts, by kind of tool, and failed tool calls",
        "Files changed and lines added or removed, as counts only",
        "Provider and model names, and project folder names",
    ]
    static let never = [
        "Prompts, replies or chat history",
        "Diffs, code or file contents",
        "Full paths, terminal output, environment variables or credentials",
        "Sessions started outside agterm and agmux",
    ]

    var body: some View {
        Section {
            switch account.state {
            case .signedOut:
                LabeledContent("Not signed in") {
                    Button("Sign in…") { confirming = true }
                }
            case let .linking(_, url):
                LabeledContent("Waiting for you to approve in the browser…") {
                    HStack {
                        Button("Open Again") { NSWorkspace.shared.open(url) }
                        Button("Cancel") { account.cancelLinking() }
                    }
                }
            case let .signedIn(name, email):
                LabeledContent(email.map { "\(name) · \($0)" } ?? name) {
                    Button("Sign Out") { account.signOut() }
                }
                if let last = account.lastUpload {
                    LabeledContent("Last upload", value: last.formatted(.relative(presentation: .named)))
                }
            }
            if let error = account.lastError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("agmux Teams")
        } footer: {
            Text("Reports the sessions you run in agterm to your team, the same way agmux does. agterm links as its own device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Share agterm sessions with your team?").font(.headline)
                list("Shared with your team", Self.shared)
                list("Never shared", Self.never)
                Text("Uploads happen every few minutes while you're signed in. Sign out here at any time.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Continue in Browser") {
                        confirming = false
                        account.startLinking()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(items, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Pair agterm Remote (or the agmux phone app) with this Mac's agterm tabs.
struct PhoneSection: View {
    @ObservedObject var remote: RemoteClient

    var body: some View {
        Section {
            Toggle("Allow your phone to see and type into agterm tabs", isOn: Binding(
                get: { remote.isEnabled }, set: { remote.setEnabled($0) }))
            if remote.isEnabled {
                LabeledContent(status) {
                    Button("Pair a Phone…") { remote.pair() }
                }
                if let pairing = remote.pairing {
                    HStack(alignment: .top, spacing: 14) {
                        if let qr = QRCode.image(pairing.url) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 132, height: 132)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan with your iPhone's camera to open agterm Remote. Pair code:")
                                .fixedSize(horizontal: false, vertical: true)
                            Text(pairing.code).font(.system(.title2, design: .monospaced).weight(.semibold))
                            Text("Expires \(pairing.expires.formatted(date: .omitted, time: .shortened)).")
                                .foregroundStyle(.secondary)
                            Button("Copy Link for the agmux Phone App") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pairing.agmuxURL, forType: .string)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Phone")
        } footer: {
            Text("Uses the agmux remote relay over an encrypted connection (TLS; the relay can read what passes through it). "
                 + "agterm Remote shows each tab's live screen and can press keys in it. The agmux phone app works too, "
                 + "but keeps one paired Mac at a time, so pairing agterm replaces agmux on that phone.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: String {
        switch remote.connection {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .online: remote.phones.isEmpty ? "Connected, no phones paired" : "\(remote.phones.count) phone\(remote.phones.count == 1 ? "" : "s") paired, \(remote.phonesOnline) online"
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
