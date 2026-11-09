import Foundation

/// `agterm-remote`, the command agents use to run something on a paired Mac: what it was asked
/// to do, where the project goes on the other Mac, and the command that runs there.
public enum MacTask {
    /// The folder on the worker Mac that holds every project sent to it.
    public static let tasksFolder = "agterm-tasks"

    public enum Command: Equatable {
        case run(Run)
        case list
        case help
    }

    public struct Run: Equatable {
        /// Which paired Mac; nil for the first one.
        public var mac: String?
        /// Copy the project there first.
        public var sync = true
        /// Copy files the command changed back afterwards.
        public var back = false
        /// A shell command line, run by the other Mac's login shell.
        public var command: String

        public init(mac: String? = nil, sync: Bool = true, back: Bool = false, command: String) {
            self.mac = mac
            self.sync = sync
            self.back = back
            self.command = command
        }
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static let usage = """
        usage: agterm-remote run [--mac <name>] [--no-sync] [--back] -- <command…>
               agterm-remote list

        run    Copies this folder's git repo (or the folder) to the other Mac, runs the command
               there in its login shell, shows its output as it runs and exits with its status.
               Ctrl-C stops it there.
               --mac <name>  a paired Mac other than the first
               --no-sync     don't copy first; use what the last run copied
               --back        afterwards, copy back files the command made or changed
                             (files you changed here meanwhile are kept)
               One word after -- is run as a command line ("make -j8 && ./test");
               several are quoted as separate words.
        list   The Macs paired in agterm Settings → Macs, and whether each answers.
        """

    /// Parses the words after `agterm-remote`.
    public static func parse(_ words: [String]) throws -> Command {
        guard let verb = words.first else { return .help }
        switch verb {
        case "list": return .list
        case "help", "-h", "--help": return .help
        case "run": break
        default: throw UsageError(description: "unknown command \(verb)")
        }
        var run = Run(command: "")
        var rest = words.dropFirst()
        while let word = rest.first {
            rest = rest.dropFirst()
            switch word {
            case "--":
                run.command = commandLine(Array(rest))
                rest = []
            case "--mac":
                guard let name = rest.first, !name.isEmpty else { throw UsageError(description: "--mac needs a name") }
                run.mac = name
                rest = rest.dropFirst()
            case "--no-sync": run.sync = false
            case "--back": run.back = true
            default:
                guard !word.hasPrefix("-") else { throw UsageError(description: "unknown option \(word)") }
                run.command = commandLine([word] + rest)
                rest = []
            }
        }
        guard !run.command.trimmingCharacters(in: .whitespaces).isEmpty else { throw UsageError(description: "no command to run") }
        return .run(run)
    }

    /// One word is a command line as written; several are quoted word by word.
    static func commandLine(_ words: [String]) -> String {
        words.count == 1 ? words[0] : words.map(quoted).joined(separator: " ")
    }

    /// `word` in single quotes for a POSIX shell, unless it needs none.
    public static func quoted(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_./=:,+@%".unicodeScalars.contains($0)
        }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where `folder` goes on the worker Mac: under its home, in `agterm-tasks/<this Mac>/`, at
    /// the same path relative to this Mac's home (or the whole path, for a folder outside it).
    /// Its own copy, so nothing the worker Mac's user keeps is ever overwritten.
    public static func remoteFolder(_ folder: String, localHome: String, remoteHome: String, client: String) -> String {
        let home = localHome.hasSuffix("/") ? String(localHome.dropLast()) : localHome
        let relative = folder.hasPrefix(home + "/") ? String(folder.dropFirst(home.count + 1)) : "root" + folder
        return remoteHome + "/" + tasksFolder + "/" + safeName(client) + "/" + relative
    }

    /// `cwd` inside `folder`, moved to the same place in `remote`.
    public static func remoteCwd(_ cwd: String, folder: String, remote: String) -> String {
        cwd == folder ? remote : cwd.hasPrefix(folder + "/") ? remote + cwd.dropFirst(folder.count) : remote
    }

    /// Runs `command` in `cwd` with the worker's login shell, so its PATH (Homebrew and the like)
    /// applies. Not `exec`ed: the login shell stays the process group leader the gateway stops.
    public static func execArgv(cwd: String, command: String) -> [String] {
        ["/bin/sh", "-c", #"cd "$1" || exit 1; "${SHELL:-/bin/sh}" -l -c "$2""#, "agterm-remote", cwd, command]
    }

    /// Letters, digits, `-` and `_`; anything else becomes `-`.
    public static func safeName(_ name: String) -> String {
        let safe = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" })
        return safe.isEmpty ? "mac" : safe
    }
}
