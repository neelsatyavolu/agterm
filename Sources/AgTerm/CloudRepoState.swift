import AgTermCore
import CryptoKit
import Foundation

/// What a moved repo looked like on this Mac when it went to the cloud, so Bring Back can tell
/// whether it changed here meanwhile (another tab, an editor). If it did, the cloud's changes
/// come back as a patch instead of over it, as `codex apply` and Claude's teleport refuse to
/// overwrite a changed tree. Kept in user defaults by folder.
enum CloudRepoState {
    struct Record: Codable, Equatable {
        /// HEAD when it moved: the base of the cloud's changes.
        let base: String
        let fingerprint: String
    }

    private static let key = "cloudRepoStates"

    /// HEAD and a fingerprint of everything git sees as changed (with sizes and modification
    /// times); nil outside a git repo.
    static func current(_ folder: String) -> Record? {
        guard let head = git(folder, ["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty,
              let status = git(folder, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
        var text = head + "\n" + status
        for entry in status.split(separator: "\0") where entry.count > 3 {
            let path = folder + "/" + entry.dropFirst(3)
            let info = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (info?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            text += "\n\(path) \(size) \(modified)"
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return Record(base: head, fingerprint: digest)
    }

    static func remember(_ folder: String) {
        guard let record = current(folder) else { return forget(folder) }
        var all = stored()
        all[folder] = record
        save(all)
    }

    static func recorded(_ folder: String) -> Record? { stored()[folder] }

    static func forget(_ folder: String) {
        var all = stored()
        guard all.removeValue(forKey: folder) != nil else { return }
        save(all)
    }

    /// The repo's git folder here, where a patch from the cloud is kept.
    static func gitDir(_ folder: String) -> String? {
        guard let dir = git(folder, ["rev-parse", "--absolute-git-dir"])?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { return nil }
        return dir
    }

    private static func stored() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private static func save(_ all: [String: Record]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }

    private static func git(_ folder: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
