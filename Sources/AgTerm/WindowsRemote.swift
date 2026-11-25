import AgTermCore
import AgTermSessionKit
import Foundation

/// `agterm-remote run` for a Windows PC (agterm-worker): no rsync there, so the project goes
/// over as a tar of the files that differ (`WindowsSync`), the command runs in PowerShell, and
/// `--back` brings back what the PC's listing shows changed while it ran.
enum WindowsRemote {
    private static let highWater = 1024 * 1024
    private static let chunk = 64 * 1024

    /// Copies `folder` there as `remote`, runs the command in `remoteCwd`; its exit status.
    static func perform(_ task: MacTask.Run, on host: MacHost, name: String, folder: String, remote: String, remoteCwd: String,
                        started: Date) -> Int32 {
        if task.sync {
            note("copying \(folder) to \(name)…")
            do {
                try push(folder, to: remote, via: host)
            } catch {
                fail("copying to \(name) failed: \(error)")
            }
        }
        let before = task.back ? try? manifest(remote, via: host) : nil
        note("running on \(name) in \(remoteCwd)")
        let status = MacRemote.stream([WindowsSync.worker, "shell", remoteCwd, task.windowsCommand], on: host, name: name)
        guard task.back else { return status }
        do {
            try pull(remote, to: folder, since: before ?? [:], started: started, via: host, name: name)
        } catch {
            note("copying back failed: \(error)")
            return status == 0 ? 1 : status
        }
        return status
    }

    // MARK: Sending

    private static func push(_ folder: String, to remote: String, via host: MacHost) throws {
        let local = localFiles(folder)
        let there = try manifest(remote, via: host)
        let candidates = there.keys.filter { local[$0] == nil }
        let ignored = gitIgnored(candidates, in: folder)
        let plan = WindowsSync.plan(local: local, remote: there) { ignored.contains($0) }
        if !plan.delete.isEmpty {
            let removed = try host.run([WindowsSync.worker, "delete", remote], input: WindowsSync.pathList(plan.delete), timeout: 120)
            guard removed.status == 0 else { throw MacLink.ConnectError(description: "removing old files failed: \(removed.stderr)") }
        }
        guard !plan.send.isEmpty else { return }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // No AppleDouble `._` files or extended attributes: the PC would keep them as files.
        tar.arguments = ["-c", "-f", "-", "--no-mac-metadata", "--no-xattrs", "-C", folder, "--null", "-T", "-"]
        tar.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 }
        let list = Pipe(), archive = Pipe()
        tar.standardInput = list
        tar.standardOutput = archive
        try tar.run()
        DispatchQueue.global().async {
            list.fileHandleForWriting.write(WindowsSync.pathList(plan.send))
            try? list.fileHandleForWriting.close()
        }
        let status = try transfer([WindowsSync.worker, "receive", remote], via: host, from: archive.fileHandleForReading, to: nil)
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw MacLink.ConnectError(description: "tar couldn't read some files here") }
        guard status == 0 else { throw MacLink.ConnectError(description: "the PC couldn't write the files (status \(status))") }
    }

    /// The files `agterm-remote` sends: a git repo's tracked and not-ignored files plus its
    /// .git folder, or everything in a folder that isn't a repo; never the rebuildable folders.
    static func localFiles(_ folder: String) -> [String: WindowsSync.Entry] {
        let excluded = CloudMovePlan.excluded
        var paths: [String]
        if let listed = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: folder) {
            paths = listed.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            paths += walk(folder + "/.git", excluded: []).map { ".git/" + $0 }
        } else {
            paths = walk(folder, excluded: excluded)
        }
        var files: [String: WindowsSync.Entry] = [:]
        for path in paths where !WindowsSync.isExcluded(path, excluded: excluded) {
            var info = stat()
            // Regular files only: a deleted tracked file, a submodule or a symlink isn't sent.
            guard lstat(folder + "/" + path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            files[path] = WindowsSync.Entry(size: Int64(info.st_size), mtime: Int64(info.st_mtimespec.tv_sec))
        }
        return files
    }

    /// Relative paths of the files under `root`, not entering folders named in `excluded`.
    private static func walk(_ root: String, excluded: [String]) -> [String] {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if excluded.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            paths.append(String(url.path.dropFirst(base.path.count + 1)))
        }
        return paths
    }

    /// Which of `paths` git ignores in `folder`: what the PC built or installed, kept there.
    private static func gitIgnored(_ paths: [String], in folder: String) -> Set<String> {
        guard !paths.isEmpty, let out = git(["check-ignore", "-z", "--stdin"], in: folder, input: WindowsSync.pathList(paths), okStatuses: [0, 1]) else { return [] }
        return Set(out.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    private static func git(_ arguments: [String], in folder: String, input: Data? = nil, okStatuses: Set<Int32> = [0]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder] + arguments
        let out = Pipe(), feed = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : feed
        guard (try? process.run()) != nil else { return nil }
        if let input {
            DispatchQueue.global().async {
                feed.fileHandleForWriting.write(input)
                try? feed.fileHandleForWriting.close()
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return okStatuses.contains(process.terminationStatus) ? data : nil
    }

    private static func manifest(_ remote: String, via host: MacHost) throws -> [String: WindowsSync.Entry] {
        let out = Pipe()
        let reader = DispatchQueue.global()
        var data = Data()
        let read = DispatchGroup()
        read.enter()
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        let status = try transfer([WindowsSync.worker, "manifest", remote] + WindowsSync.skipArguments(CloudMovePlan.excluded),
                                  via: host, from: nil, to: out.fileHandleForWriting)
        try? out.fileHandleForWriting.close()
        read.wait()
        guard status == 0 else { throw MacLink.ConnectError(description: "couldn't list the files there (status \(status))") }
        return WindowsSync.parseManifest(data)
    }

    // MARK: Copying back

    /// Files whose size or time changed there since `before`, except ones you changed here
    /// after `started` and anything in .git.
    private static func pull(_ remote: String, to folder: String, since before: [String: WindowsSync.Entry], started: Date,
                             via host: MacHost, name: String) throws {
        let after = try manifest(remote, via: host)
        let keep = Set(MacRemote.changedHere(in: folder, since: started))
        let changed = after.filter { $0.key != ".git" && !$0.key.hasPrefix(".git/") && before[$0.key] != $0.value && !keep.contains($0.key) }
            .map(\.key).sorted()
        note("copying \(changed.count) changed file(s) back from \(name)…" + (keep.isEmpty ? "" : " (keeping \(keep.count) file(s) you changed here meanwhile)"))
        guard !changed.isEmpty else { return }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-x", "-f", "-", "-C", folder]
        let archive = Pipe()
        tar.standardInput = archive
        try tar.run()
        let status = try transfer([WindowsSync.worker, "pack", remote], via: host, input: WindowsSync.pathList(changed),
                                  from: nil, to: archive.fileHandleForWriting)
        try? archive.fileHandleForWriting.close()
        tar.waitUntilExit()
        guard status == 0 else { throw MacLink.ConnectError(description: "the PC couldn't pack the files (status \(status))") }
        guard tar.terminationStatus == 0 else { throw MacLink.ConnectError(description: "tar couldn't write some files here") }
    }

    // MARK: Plumbing

    /// Runs `argv` there with stdin from `input` then `source` (to its end), writing its stdout
    /// to `sink`; its stderr goes to ours. Returns its exit status.
    private static func transfer(_ argv: [String], via host: MacHost, input: Data = Data(), from source: FileHandle?,
                                 to sink: FileHandle?) throws -> Int32 {
        let connection = try host.exec(argv)
        defer { connection.close() }
        let done = DispatchSemaphore(value: 0)
        // Set on the reader's queue only, before `done` is signalled.
        var result: Result<Int32, Error> = .failure(MacLink.ConnectError(description: "lost the connection"))
        var ended = false
        connection.onMessage = { message in
            guard !ended else { return }
            switch message {
            case .output(let bytes): sink?.write(bytes)
            case .stderr(let bytes): FileHandle.standardError.write(bytes)
            case .exited(_, let code):
                result = .success(code)
                ended = true
                done.signal()
            case .error(let text):
                result = .failure(WireError.remote(text))
                ended = true
                done.signal()
            default: break
            }
        }
        connection.onClose = {
            guard !ended else { return }
            ended = true
            done.signal()
        }
        connection.startReading(queue: DispatchQueue(label: "agterm.windows-remote"))
        if !input.isEmpty { try connection.send(.input(input)) }
        if let source {
            while true {
                let bytes = source.readData(ofLength: chunk)
                guard !bytes.isEmpty else { break }
                while connection.backlogBytes > highWater { usleep(2_000) }
                try connection.send(.input(bytes))
            }
        }
        try connection.send(.input(Data()))
        done.wait()
        return try result.get()
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("agterm-remote: \(text)\n".utf8))
    }

    private static func fail(_ text: String) -> Never {
        note(text)
        exit(255)
    }
}
