import AgTermCore
import AgTermSessionKit
import CryptoKit
import Foundation

/// `agterm-remote` (a wrapper in agterm's bin folder runs `agterm --remote …`): runs a command
/// on a paired Mac for an agent or for you. `run` copies the project there with rsync (as Move
/// to Cloud does, through `agterm --cloud-pipe`), runs the command in that Mac's login shell,
/// passes its output through as it comes and exits with its status; 255 if the Mac can't be
/// reached or the link drops, as ssh does. `AGTERM_MAC_PAIRING` (a pairing code) stands in for
/// Settings → Macs. See `MacTask` for the words it takes.
enum MacRemote {
    static let flag = "--remote"

    static func run(_ arguments: [String]) -> Never {
        let words = Array(arguments.drop { $0 != flag }.dropFirst())
        signal(SIGPIPE, SIG_IGN)
        // Started in the background, or by a tool that ignores them, it must still stop (and
        // stop the command there, as the link drops) on Ctrl-C or a timeout's SIGTERM.
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        do {
            switch try MacTask.parse(words) {
            case .help:
                print(MacTask.usage)
                exit(0)
            case .list: exit(list())
            case .run(let task): exit(perform(task))
            }
        } catch {
            fail("\(error)\n\n\(MacTask.usage)", status: 2)
        }
    }

    private static var pairings: [MacPairing] {
        MacHost.fromEnvironment.map { [$0.pairing] } ?? MacPairings.all
    }

    private static let notPaired = """
        no Mac is paired. On the other Mac, turn on agterm Settings → Macs → "Let my other Macs run tasks on this Mac" \
        and copy its pairing code; then add it in Settings → Macs on this one.
        """

    private static func list() -> Int32 {
        let macs = pairings
        guard !macs.isEmpty else { fail(notPaired) }
        for (index, mac) in macs.enumerated() {
            let problem = MacHost(mac).check()
            print("\(mac.name)\(index == 0 ? " (default)" : "")  \(mac.host):\(mac.port)  \(problem.map { "not reachable: \($0)" } ?? "ready")")
        }
        return 0
    }

    private static func perform(_ task: MacTask.Run) -> Int32 {
        let macs = pairings
        guard !macs.isEmpty else { fail(notPaired) }
        guard let pairing = task.mac.map({ name in macs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }) ?? macs.first else {
            fail("no paired Mac is called \(task.mac ?? ""); paired: \(macs.map(\.name).joined(separator: ", "))")
        }
        let host = MacHost(pairing)
        let home = NSHomeDirectory()
        let cwd = CloudMove.realPath(FileManager.default.currentDirectoryPath)
        guard let folder = CloudMovePlan.folder(cwd: cwd, gitRoot: CloudMove.gitRoot(of: cwd), hasAgent: true,
                                                home: home, resolve: CloudMove.realPath) else {
            fail("run it from a project folder: your home folder, or anything above it, isn't copied", status: 2)
        }
        let remote: String
        do {
            remote = MacTask.remoteFolder(folder, localHome: CloudMove.realPath(home), remoteHome: try host.home(),
                                          client: MacWorker.computerName)
        } catch {
            fail("can't reach \(pairing.name): \(MacHost.explain(error))")
        }
        // One run at a time in each copy: another agent's upload would change files under this one's build.
        let lock = lockCopy(remote, on: pairing.name)
        defer { close(lock) }
        // Files changed here from now on are newer than what comes back, whatever the clocks say.
        let started = Date()
        if task.sync {
            note("copying \(folder) to \(pairing.name)…")
            do {
                try push(folder, to: remote, via: host)
            } catch {
                fail("copying to \(pairing.name) failed: \(error)")
            }
        }
        note("running on \(pairing.name) in \(MacTask.remoteCwd(cwd, folder: folder, remote: remote))")
        let status = stream(MacTask.execArgv(cwd: MacTask.remoteCwd(cwd, folder: folder, remote: remote), command: task.command),
                            on: host, name: pairing.name)
        guard task.back else { return status }
        let keep = changedHere(in: folder, since: started)
        note("copying changes back from \(pairing.name)…" + (keep.isEmpty ? "" : " (keeping \(keep.count) file(s) you changed here meanwhile)"))
        do {
            try CloudSync.copy(["mac:" + remote + "/"], to: folder + "/", excluding: CloudMovePlan.excluded + [".git"],
                               rules: CloudMovePlan.ignoreRules(gitIgnored: keep.joined(separator: "\0")),
                               options: ["--update"], via: host)
        } catch {
            note("copying back failed: \(error)")
            return status == 0 ? 1 : status
        }
        return status
    }

    /// The folder as it is here, without git-ignored files or rebuildable folders. `--delete`
    /// leaves excluded files alone, so what's ignored on either side stays there: what the other
    /// Mac installed or built (node_modules, caches) is kept for the next run.
    private static func push(_ folder: String, to remote: String, via host: MacHost) throws {
        let made = try host.run(["/bin/mkdir", "-p", remote])
        guard made.status == 0 else { throw MacLink.ConnectError(description: "couldn't make \(remote): \(made.stderr)") }
        let there = try? host.run(["/usr/bin/env", "git", "-C", remote] + CloudSync.gitIgnoredArguments, timeout: 60)
        let ignored = CloudSync.gitIgnored(in: folder) + "\0" + (there?.status == 0 ? there?.stdout ?? "" : "")
        try CloudSync.copy([folder + "/"], to: "mac:" + remote + "/", excluding: CloudMovePlan.excluded,
                           rules: CloudMovePlan.ignoreRules(gitIgnored: ignored), options: ["--delete"], via: host)
    }

    /// Files under `folder` (relative paths) modified after `date`, leaving out .git and rebuildable folders.
    private static func changedHere(in folder: String, since date: Date) -> [String] {
        let skip = Set(CloudMovePlan.excluded + [".git"])
        let root = URL(fileURLWithPath: folder)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return [] }
        var changed: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skip.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            if let modified = values?.contentModificationDate, modified > date {
                changed.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return changed
    }

    /// Holds a lock for the copy at `remote` on `mac` until the descriptor is closed (or the
    /// process ends), waiting for another run that holds it.
    private static func lockCopy(_ remote: String, on mac: String) -> Int32 {
        let key = SHA256.hash(data: Data((mac + "\0" + remote).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let path = NSTemporaryDirectory() + "agterm-remote-" + key + ".lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return fd }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            note("waiting for another agterm-remote run in this project on \(mac) to finish…")
            flock(fd, LOCK_EX)
        }
        return fd
    }

    /// Runs `argv` there with no input, writing its output here as it comes; its exit status.
    private static func stream(_ argv: [String], on host: MacHost, name: String) -> Int32 {
        let connection: WireConnection
        do {
            connection = try host.exec(argv)
            try connection.send(.input(Data()))
        } catch {
            fail("can't run it on \(name): \(MacHost.explain(error))")
        }
        let done = DispatchSemaphore(value: 0)
        // Both set on the reader's queue, which also calls onClose: the gateway hangs up right after `exited`.
        var status: Int32 = 255
        var ended = false
        connection.onMessage = { message in
            guard !ended else { return }
            switch message {
            case .output(let bytes): FileHandle.standardOutput.write(bytes)
            case .stderr(let bytes): FileHandle.standardError.write(bytes)
            case .exited(_, let code):
                status = code
                ended = true
                done.signal()
            case .error(let text):
                note("\(name): \(text)")
                ended = true
                done.signal()
            default: break
            }
        }
        connection.onClose = {
            guard !ended else { return }
            ended = true
            note("lost the connection to \(name); the command was stopped there")
            done.signal()
        }
        connection.startReading(queue: DispatchQueue(label: "agterm.remote"))
        done.wait()
        connection.close()
        return status
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("agterm-remote: \(text)\n".utf8))
    }

    private static func fail(_ text: String, status: Int32 = 255) -> Never {
        note(text)
        exit(status)
    }
}
