import Foundation

/// What agents are told about `agterm-remote`: at launch, and in the note agterm leaves in live
/// agent tabs when a computer is paired.
public enum RemoteInstructions {
    /// A paired computer as agents hear of it.
    public struct Computer: Equatable {
        public var name: String
        public var isWindows: Bool

        public init(name: String, isWindows: Bool) {
            self.name = name
            self.isWindows = isWindows
        }
    }

    /// The instructions for `computers` (in pairing order, the first the default); nil with none.
    public static func text(_ computers: [Computer]) -> String? {
        guard let first = computers.first else { return nil }
        let macs = computers.filter { !$0.isWindows }.map(\.name)
        let pcs = computers.filter(\.isWindows).map(\.name)
        let listed = [macs.isEmpty ? nil : "Macs \(quoted(macs))", pcs.isEmpty ? nil : "Windows PCs \(quoted(pcs))"]
            .compactMap { $0 }.joined(separator: " and ")
        var text = """
            ## Other computers (agterm-remote)
            This Mac is paired with \(listed) in agterm (default "\(first.name)"). Run CPU-heavy or long commands
            there instead of here: full builds, test suites, benchmarks, renders, data processing. From the project folder:
                agterm-remote run [--mac <name>] -- "<command line>"
            It copies the git repo there (without git-ignored files, so node_modules, build output and .env files stay
            here), runs the command, prints its output as it runs and exits with its status. What it installs or builds
            there stays for the next run, so install dependencies in the command when needed:
                agterm-remote run -- "npm ci && npm test"
            Options before --: `--back` copies back files the command made or changed; `--mac <name>` picks another
            computer; `--no-sync` reuses the last copy. Keep quick commands, git, and anything that needs this Mac's apps,
            simulators or signed-in tools here. `agterm-remote list` shows which computers answer.
            """
        if !macs.isEmpty {
            text += "\nOn a Mac the command runs in its login shell (zsh or bash)."
        }
        if !pcs.isEmpty {
            text += """

                On a Windows PC the command runs in PowerShell (PowerShell 7 if installed, else Windows PowerShell 5.1),
                so write PowerShell, not sh: `;` between commands, `$env:NAME = "value"` for variables, and use
                Windows-only tools there (MSVC, .NET, Windows tests and installers, a Windows GPU). On 5.1 `&&` doesn't
                work; run `agterm-remote list` to see which. Example:
                    agterm-remote run --mac "\(pcs[0])" -- "dotnet test; if ($LASTEXITCODE) { exit $LASTEXITCODE }"
                """
        }
        return text
    }

    /// The one-line note typed into agent tabs that were already running when `computer` was
    /// paired: they started without the instructions above.
    public static func pairedNote(_ computer: Computer) -> String {
        let shell = computer.isWindows ? "PowerShell (write PowerShell, not sh)" : "its login shell"
        // Typed into a terminal: a name from a pairing code mustn't carry control characters.
        let name = String(String.UnicodeScalarView(computer.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return "[Note from agterm, not from your user: no reply needed.] The user just paired the "
            + (computer.isWindows ? "Windows PC" : "Mac") + " \"\(name)\" for running CPU-heavy or long commands "
            + "(builds, test suites, renders). From the project folder, `agterm-remote run --mac \"\(name)\" -- \"<command>\"` "
            + "copies the git repo there, runs the command in \(shell) and streams its output back; `--back` copies changed "
            + "files back. `agterm-remote help` has the details. Use it when it helps your current task; otherwise carry on."
    }

    private static func quoted(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}
