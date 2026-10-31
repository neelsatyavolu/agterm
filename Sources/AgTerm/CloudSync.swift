import AgTermCore
import AgTermSessionKit
import Foundation

/// Copies folders and files to and from the cloud machine at the same paths, with macOS's rsync
/// talking to rsync there through the gateway (`agterm --cloud-pipe`). Only changes go after
/// the first copy. Nothing is deleted on either side. Blocks; not for the main queue.
enum CloudSync {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let rsync = "/usr/bin/rsync"

    /// `folders` are copied without `CloudMovePlan.excluded`; `files` (files or folders) whole.
    /// Paths that don't exist here are skipped. `progress` gets the share sent so far, 0 to 1,
    /// on a background queue; files the machine already has go faster than it says.
    static func push(folders: [String], files: [String], to cloud: CloudHost, progress: ((Double) -> Void)? = nil) throws {
        let folders = folders.filter(isDirectory)
        let files = files.filter { FileManager.default.fileExists(atPath: $0) }
        let total = folders.reduce(0) { $0 + size(of: $1, excluding: CloudMovePlan.excluded) } + files.reduce(0) { $0 + size(of: $1, excluding: []) }
        var done: Int64 = 0
        // Each copy reports from its own timer thread, on top of what the copies before it sent.
        let report = { (base: Int64) in
            progress.map { report in { (sent: Int64) in report(total > 0 ? min(1, Double(base + sent) / Double(total)) : 0) } }
        }
        for folder in folders {
            try makeFolder(folder, on: cloud)
            let sent = try copy([folder + "/"], to: "cloud:" + folder + "/", excluding: CloudMovePlan.excluded, via: cloud, progress: report(done))
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

    /// Bytes in the files under `path`, leaving out folders named in `excluded`.
    static func size(of path: String, excluding excluded: [String]) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard isDirectory(path) else { return Int64((try? url.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        let skip = Set(excluded)
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if skip.contains(file.lastPathComponent) { walker.skipDescendants() }
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
                try copy(["cloud:" + folder + "/"], to: folder + "/", excluding: excluded, options: ["--update"], via: cloud)
            }
        }
    }

    private static func makeFolder(_ path: String, on cloud: CloudHost) throws {
        let result = try cloud.run(["/usr/bin/env", "mkdir", "-p", path])
        guard result.status == 0 else { throw Failure(description: "couldn't make \(path) on the cloud machine: \(result.stderr)") }
    }

    /// `sources` and `destination` name the cloud side as `cloud:<path>`. Returns the bytes sent.
    @discardableResult
    private static func copy(_ sources: [String], to destination: String, excluding excluded: [String], options: [String] = [],
                             via cloud: CloudHost, progress: ((Int64) -> Void)? = nil) throws -> Int64 {
        guard let binary = Bundle.main.executableURL?.path, !binary.contains(" ") else {
            throw Failure(description: "agterm's path has a space, which rsync's -e can't take")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsync)
        process.arguments = ["-a"] + options + excluded.flatMap { ["--exclude", $0] } + ["-e", "\(binary) \(CloudPipe.flag)"]
            + sources + [destination]
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
