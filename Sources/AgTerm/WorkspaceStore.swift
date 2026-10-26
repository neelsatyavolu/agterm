import AgTermCore
import Foundation

/// Saves the open tabs so the next launch can reopen them. The file holds terminal history,
/// which can include secrets, so it is readable by the owner only.
enum WorkspaceStore {
    /// ~/Library/Application Support/<bundle id>/workspace.json. Unbundled debug builds use
    /// "agterm-dev" so they never touch the installed app's tabs; AGTERM_STATE_DIR overrides.
    /// A self-test without AGTERM_STATE_DIR gets a folder of its own, so it never shares a
    /// sessions helper (or tabs) with a running debug build.
    static var fileURL: URL {
        if let dir = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("workspace.json")
        }
        #if DEBUG
        if let dir = selfTestDir { return dir.appendingPathComponent("workspace.json") }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "agterm-dev", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    #if DEBUG
    private static let selfTestDir: URL? = ProcessInfo.processInfo.environment["AGTERM_SELFTEST"] == nil ? nil
        : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-selftest-\(getpid())", isDirectory: true)
    #endif

    static func load() -> SavedWorkspace? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try SavedWorkspace.decode(data)
        } catch {
            NSLog("agterm: ignoring unreadable saved tabs at %@: %@", fileURL.path, String(describing: error))
            return nil
        }
    }

    static func save(_ workspace: SavedWorkspace) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try workspace.encoded().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("agterm: couldn't save tabs to %@: %@", url.path, error.localizedDescription)
        }
    }
}
