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
    /// Paths that don't exist here are skipped.
    static func push(folders: [String], files: [String], to cloud: CloudHost) throws {
        for folder in folders where isDirectory(folder) {
            try makeFolder(folder, on: cloud)
            try copy([folder + "/"], to: "cloud:" + folder + "/", excluding: CloudMovePlan.excluded, via: cloud)
        }
        for path in files where FileManager.default.fileExists(atPath: path) {
            if isDirectory(path) {
                try makeFolder(path, on: cloud)
                try copy([path + "/"], to: "cloud:" + path + "/", excluding: [], via: cloud)
            } else {
                let parent = (path as NSString).deletingLastPathComponent
                try makeFolder(parent, on: cloud)
                try copy([path], to: "cloud:" + parent + "/", excluding: [], via: cloud)
            }
        }
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

    /// `sources` and `destination` name the cloud side as `cloud:<path>`.
    private static func copy(_ sources: [String], to destination: String, excluding excluded: [String], options: [String] = [],
                             via cloud: CloudHost) throws {
        guard let binary = Bundle.main.executableURL?.path, !binary.contains(" ") else {
            throw Failure(description: "agterm's path has a space, which rsync's -e can't take")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsync)
        process.arguments = ["-a"] + options + excluded.flatMap { ["--exclude", $0] } + ["-e", "\(binary) \(CloudPipe.flag)"]
            + sources + [destination]
        process.environment = ProcessInfo.processInfo.environment.merging(cloud.environment) { $1 }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "rsync of \(sources.joined(separator: ", ")) failed (\(process.terminationStatus)): "
                + String(decoding: message, as: UTF8.self))
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
