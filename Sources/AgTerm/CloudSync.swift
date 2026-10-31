import AgTermCore
import AgTermSessionKit
import CryptoKit
import Foundation

/// Copies folders and files to and from the cloud machine at the same paths, with macOS's rsync
/// talking to rsync there through the gateway (`agterm --cloud-pipe`). Only changes go after
/// the first copy. Nothing is deleted on either side. Blocks; not for the main queue.
enum CloudSync {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let rsync = "/usr/bin/rsync"

    /// `folders` are copied without `CloudMovePlan.excluded` or what git ignores in them; `files`
    /// (files or folders) whole. Paths that don't exist here are skipped. `progress` gets the
    /// share sent so far, 0 to 1, on a background queue; files the machine already has go
    /// faster than it says.
    static func push(folders: [String], files: [String], to cloud: CloudHost, progress: ((Double) -> Void)? = nil) throws {
        let folders = folders.filter(isDirectory)
        let files = files.filter { FileManager.default.fileExists(atPath: $0) }
        let ignored = Dictionary(uniqueKeysWithValues: folders.map { ($0, gitIgnored(in: $0)) })
        let total = folders.reduce(0) { $0 + size(of: $1, excluding: CloudMovePlan.excluded, ignored: ignored[$1] ?? "") }
            + files.reduce(0) { $0 + size(of: $1, excluding: []) }
        var done: Int64 = 0
        // Each copy reports from its own timer thread, on top of what the copies before it sent.
        let report = { (base: Int64) in
            progress.map { report in { (sent: Int64) in report(total > 0 ? min(1, Double(base + sent) / Double(total)) : 0) } }
        }
        for folder in folders {
            try makeFolder(folder, on: cloud)
            let sent = try copy([folder + "/"], to: "cloud:" + folder + "/", excluding: CloudMovePlan.excluded,
                                rules: CloudMovePlan.ignoreRules(gitIgnored: ignored[folder] ?? ""), via: cloud, progress: report(done))
            done += sent
        }
        for path in files {
            let sent: Int64
            if isDirectory(path) {
                try makeFolder(path, on: cloud)
                sent = try copy([path + "/"], to: "cloud:" + path + "/", excluding: [], via: cloud, progress: report(done))
            } else {
                let parent = (path as NSString).deletingLastPathComponent
                try makeFolder(parent, on: cloud)
                sent = try copy([path], to: "cloud:" + parent + "/", excluding: [], via: cloud, progress: report(done))
            }
            done += sent
        }
    }

    /// What git ignores in `folder` (`CloudMovePlan.ignoreRules` takes it); empty outside a repo.
    static func gitIgnored(in folder: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + gitIgnoredArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }

    private static let gitIgnoredArguments = ["ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z"]

    /// Bytes in the files under `path`, leaving out folders named in `excluded` and what `ignored`
    /// (`gitIgnored(in:)`) lists, as the copy does.
    static func size(of path: String, excluding excluded: [String], ignored: String = "") -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard isDirectory(path) else { return Int64((try? url.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        let skip = Set(excluded)
        let root = url.standardizedFileURL.path + "/"
        let rules = Set(CloudMovePlan.ignoreRules(gitIgnored: ignored).map { String($0.dropFirst()) })
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(root.count))
            if values.isDirectory == true {
                if skip.contains(file.lastPathComponent) || rules.contains(relative + "/") { walker.skipDescendants() }
            } else if rules.contains(relative) {
                continue
            } else {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Brings folders (without `CloudMovePlan.excluded`) and whole folders of agent state back.
    /// A file changed here more recently than there is kept, so work done on this Mac meanwhile
    /// isn't lost. Paths the cloud machine doesn't have are skipped.
    static func pull(folders: [String], files: [String], from cloud: CloudHost) throws {
        for (paths, excluded) in [(folders, CloudMovePlan.excluded), (files, [])] {
            for folder in paths where (try? cloud.run(["/usr/bin/env", "test", "-d", folder]))?.status == 0 {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                // What git ignores there (builds made in the cloud) stays there.
                let ignored = excluded.isEmpty ? "" : (try? cloud.run(["/usr/bin/env", "git", "-C", folder] + gitIgnoredArguments, timeout: 60))
                    .flatMap { $0.status == 0 ? $0.stdout : nil } ?? ""
                try copy(["cloud:" + folder + "/"], to: folder + "/", excluding: excluded, rules: CloudMovePlan.ignoreRules(gitIgnored: ignored),
                         options: ["--update"], via: cloud)
            }
        }
    }

    /// Puts a repo's dependency setup (`CloudSetup`) on the machine; returns the line a cloud tab
    /// types to run it, or nil when the repo needs none.
    static func installSetup(for folder: String, on cloud: CloudHost) throws -> String? {
        var files = Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
        if FileManager.default.fileExists(atPath: folder + "/" + CloudSetup.customScript) { files.insert(CloudSetup.customScript) }
        guard let script = CloudSetup.script(folder: folder, steps: CloudSetup.steps(files: files)) else { return nil }
        let name = SHA256.hash(data: Data(folder.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let result = try cloud.run(["/usr/bin/env", "sh", "-c", "mkdir -p \"$HOME/.agterm/setup\" && printf %s \"$1\" > \"$HOME/.agterm/setup/$2.sh\"",
                                    "sh", script, name])
        guard result.status == 0 else { throw Failure(description: "couldn't set up \(folder) on the cloud machine: \(result.stderr)") }
        return "sh ~/.agterm/setup/\(name).sh"
    }

    /// The cloud's changes to a repo since `base`, as a binary git patch: its commits, edits, and
    /// new and deleted files. A scratch index leaves the repo there as it is.
    static func changes(in folder: String, since base: String, on cloud: CloudHost) throws -> String {
        let script = """
            cd "$1" || exit 1
            index=$(mktemp) || exit 1
            trap 'rm -f "$index"' EXIT
            cp "$(git rev-parse --git-dir)/index" "$index" 2>/dev/null
            GIT_INDEX_FILE="$index" git add -A . && GIT_INDEX_FILE="$index" git diff --binary --cached "$2"
            """
        let result = try cloud.run(["/usr/bin/env", "sh", "-c", script, "sh", folder, base], timeout: 120)
        guard result.status == 0 else { throw Failure(description: "couldn't read the cloud's changes to \(folder): \(result.stderr)") }
        return result.stdout
    }

    private static func makeFolder(_ path: String, on cloud: CloudHost) throws {
        let result = try cloud.run(["/usr/bin/env", "mkdir", "-p", path])
        guard result.status == 0 else { throw Failure(description: "couldn't make \(path) on the cloud machine: \(result.stderr)") }
    }

    /// `sources` and `destination` name the cloud side as `cloud:<path>`. Returns the bytes sent.
    @discardableResult
    /// `rules` are rsync exclude patterns, such as `CloudMovePlan.ignoreRules`.
    private static func copy(_ sources: [String], to destination: String, excluding excluded: [String], rules: [String] = [],
                             options: [String] = [], via cloud: CloudHost, progress: ((Int64) -> Void)? = nil) throws -> Int64 {
        guard let binary = Bundle.main.executableURL?.path, !binary.contains(" ") else {
            throw Failure(description: "agterm's path has a space, which rsync's -e can't take")
        }
        let ruleFile = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-rules-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: ruleFile, contents: Data(rules.map { $0 + "\n" }.joined().utf8))
        defer { try? FileManager.default.removeItem(atPath: ruleFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsync)
        process.arguments = ["-a"] + options + excluded.flatMap { ["--exclude", $0] } + ["--exclude-from=" + ruleFile]
            + ["-e", "\(binary) \(CloudPipe.flag)"] + sources + [destination]
        var environment = ProcessInfo.processInfo.environment.merging(cloud.environment) { $1 }
        let counter = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-sent-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: counter, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: counter) }
        environment[CloudPipe.progressVariable] = counter
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let sent = { Int64(String(decoding: FileManager.default.contents(atPath: counter) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        let timer = progress.map { report in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { report(sent()) }
            timer.resume()
            return timer
        }
        defer { timer?.cancel() }
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "rsync of \(sources.joined(separator: ", ")) failed (\(process.terminationStatus)): "
                + String(decoding: message, as: UTF8.self))
        }
        return sent()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
