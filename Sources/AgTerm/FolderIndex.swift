import AgTermCore
import Foundation

/// Folders `cd` suggestions can jump to: the home folder a few levels down, rescanned in the
/// background when stale, plus every folder a tab has been in (counted, for ranking).
final class FolderIndex {
    static let shared = FolderIndex()

    private static let depth = 3
    private static let maxFolders = 20_000
    private static let staleAfter: TimeInterval = 120
    private static let skipped: Set<String> = ["Library", "Applications", "node_modules", "Pods", "DerivedData"]
    /// Reading these asks macOS for permission; they're scanned only with Full Disk Access or once
    /// a tab has been inside (so access was already granted).
    private static let protected: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]

    private let queue = DispatchQueue(label: "agterm.folder-index", qos: .utility)
    private let lock = NSLock()
    private var scanned: [String] = []
    private var scannedAt: Date?
    private var scanning = false
    private var visits: [String: Int] = [:]

    func visit(_ path: String) {
        lock.lock()
        visits[path, default: 0] += 1
        lock.unlock()
    }

    /// Everything known right now, with `cwd`'s own subfolders; starts a rescan if stale.
    func candidates(cwd: String) -> (folders: [String], visits: [String: Int]) {
        lock.lock()
        let folders = scanned, visits = visits
        let stale = !scanning && (scannedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true)
        if stale { scanning = true }
        lock.unlock()
        if stale { rescan(visited: Array(visits.keys)) }
        return (Self.subfolders(of: cwd) + Array(visits.keys) + folders, visits)
    }

    private func rescan(visited: [String]) {
        queue.async {
            let home = NSHomeDirectory()
            let fullDiskAccess = DiskAccess.check(home: home) == .granted
            var found: [String] = []
            for top in Self.subfolders(of: home) {
                let name = (top as NSString).lastPathComponent
                if Self.protected.contains(name), !fullDiskAccess, !visited.contains(where: { $0 == top || $0.hasPrefix(top + "/") }) { continue }
                found.append(top)
                Self.walk(top, depth: Self.depth - 1, into: &found)
                if found.count >= Self.maxFolders { break }
            }
            self.lock.lock()
            self.scanned = found
            self.scannedAt = Date()
            self.scanning = false
            self.lock.unlock()
        }
    }

    private static func walk(_ path: String, depth: Int, into found: inout [String]) {
        guard depth > 0 else { return }
        for child in subfolders(of: path) where found.count < maxFolders {
            found.append(child)
            walk(child, depth: depth - 1, into: &found)
        }
    }

    /// Visible, non-package subfolders, skipping build and dependency folders.
    static func subfolders(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  values.isPackage != true, values.isSymbolicLink != true,
                  !skipped.contains(child.lastPathComponent) else { return nil }
            return child.path
        }
    }
}
