import AgTermCore
import SwiftUI
import UIKit
import VisionKit

/// First run, or after the Mac removed this phone: scan the Mac's code, or paste its link.
struct PairView: View {
    @EnvironmentObject private var remote: Remote
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AGTERM REMOTE")
                .font(Ink.label).tracking(1).foregroundStyle(Ink.fg3)
                .padding(.bottom, 16)
            Text("Your Mac's tabs, in your pocket.")
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(Ink.fg)
                .padding(.bottom, 12)
            Text("Watch each agent's screen live, answer its prompts, type replies and stop it, from anywhere.")
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(Ink.fg2)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 12) {
                step("1", "On your Mac, open agterm Settings → Teams & Phone.")
                step("2", "Turn on the phone switch and click Pair a Phone.")
                step("3", "Scan the code with this iPhone.")
            }
            .padding(.bottom, 32)

            if let message = problem ?? remote.unpairedReason {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.danger)
                    .padding(.bottom, 16)
            }

            if remote.isPairing {
                HStack(spacing: 10) {
                    ProgressView().tint(Ink.fg2)
                    Text("Pairing…").font(Ink.mono(13)).foregroundStyle(Ink.fg2)
                }
            } else {
                HStack(spacing: 12) {
                    Button("Scan Code") { problem = nil; scanning = true }
                        .buttonStyle(InkButtonStyle(kind: .accent))
                    Button("Paste Link", action: paste)
                        .buttonStyle(InkButtonStyle(kind: .ghost))
                }
                // App Review, and anyone without agterm yet, can look around with sample tabs.
                Button("No Mac nearby? Try the demo") { problem = nil; remote.startDemo() }
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.accent)
                    .padding(.top, 20)
                    .accessibilityIdentifier("try-demo")
            }
            Spacer()
            Text("Connects through the agmux relay over TLS. agterm on the Mac must be running.")
                .font(.system(size: 12))
                .foregroundStyle(Ink.fg3)
            Link("Privacy Policy", destination: privacyPolicyURL)
                .font(.system(size: 12))
                .foregroundStyle(Ink.fg2)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.bg)
        .sheet(isPresented: $scanning) {
            ScannerSheet { link in
                scanning = false
                remote.pair(link)
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number).font(Ink.mono(13, .medium)).foregroundStyle(Ink.accent)
            Text(text).font(.system(size: 15)).foregroundStyle(Ink.fg)
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let link = PairLink(url: url) else {
            problem = "The clipboard doesn't hold a pairing link. Copy it from agterm Settings on your Mac."
            return
        }
        problem = nil
        remote.pair(link)
    }
}

/// Full-screen camera that closes on the first agterm (or agmux) pairing code it sees.
private struct ScannerSheet: View {
    let found: (PairLink) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    Scanner(found: found).ignoresSafeArea()
                } else {
                    Text("This iPhone can't scan here. Point the Camera app at the code instead, or copy the link on the Mac and use Paste Link.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.fg2)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Ink.bg)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let found: (PairLink) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairLink) -> Void
        private var done = false

        init(found: @escaping (PairLink) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, let url = URL(string: text),
                      let link = PairLink(url: url) else { continue }
                done = true
                found(link)
            }
        }
    }
}
