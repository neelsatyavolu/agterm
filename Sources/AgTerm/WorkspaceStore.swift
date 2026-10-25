import AgTermCore
import Foundation

/// Saves the open tabs so the next launch can reopen them. The file holds terminal history,
/// which can include secrets, so it is readable by the owner only.
enum WorkspaceStore {
    /// ~/Library/Application Support/<bundle id>/workspace.json. Unbundled debug builds use
    /// "agterm-dev" so they never touch the installed app's tabs; AGTERM_STATE_DIR overrides.
    static var fileURL: URL {
        if let dir = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("workspace.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "agterm-dev", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

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
