#if os(macOS)
import Darwin
import Foundation

/// The sessions helper runs from its own copy of agterm.app, one per binary, so updates never
/// touch the file it was started from. macOS stops honoring a process's privacy permissions
/// (Full Disk Access and the rest) once that file is replaced: a helper run from /Applications
/// lost them, and so did every kept tab, as soon as an update or reinstall replaced the app.
/// The copy has the same identifier and signature, so it gets the app's permissions.
public enum HelperBundle {
    /// `executable` (inside `app`) in a copy of `app` under `folder`, made if missing. Copies of
    /// other binaries that no running process uses are removed. Nil if the copy can't be made.
    public static func executable(app: URL, executable: URL, build: String, folder: URL) -> URL? {
        let appPath = app.standardizedFileURL.path + "/"
        let binaryPath = executable.standardizedFileURL.path
        guard binaryPath.hasPrefix(appPath), let key = key(for: binaryPath, build: build) else { return nil }
        let relative = app.lastPathComponent + "/" + binaryPath.dropFirst(appPath.count)
        let current = folder.appendingPathComponent(key)
        removeUnused(in: folder, keeping: key)
        let target = current.appendingPathComponent(relative)
        if FileManager.default.isExecutableFile(atPath: target.path) { return target }
        return make(current, from: app) ? target : nil
    }

    /// `<build>-<hash of the binary's size and modification date>`: a reinstall of the same
    /// build is another binary too.
    private static func key(for binary: String, build: String) -> String? {
        var info = stat()
        guard stat(binary, &info) == 0 else { return nil }
        let stamp = "\(info.st_size) \(info.st_mtimespec.tv_sec) \(info.st_mtimespec.tv_nsec)"
        let safeBuild = build.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return String(safeBuild) + "-" + String(format: "%08x", SessionPaths.fnv1a32(stamp))
    }

    /// Copies `app` into `destination` through a temporary folder, so a half-made copy is never used.
    private static func make(_ destination: URL, from app: URL) -> Bool {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
            // ditto keeps the signature, extended attributes and modification dates.
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = [app.path, partial.appendingPathComponent(app.lastPathComponent).path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            if rename(partial.path, destination.path) != 0 {
                // Another launch made it first.
                guard fileManager.fileExists(atPath: destination.path) else { throw POSIXError.current }
                try? fileManager.removeItem(at: partial)
            }
            return true
        } catch {
            NSLog("agterm: couldn't copy the app for the sessions helper: %@", String(describing: error))
            try? fileManager.removeItem(at: partial)
            return false
        }
    }

    /// Removes every copy but `key` that no running process was started from.
    private static func removeUnused(in folder: URL, keeping key: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let real = realpath(folder.path, nil) else { return }
        // realpath, like the kernel's paths: URL.resolvingSymlinksInPath turns /private/var into /var.
        let root = String(cString: real) + "/"
        free(real)
        let inUse = Set(runningExecutables().compactMap { path -> String? in
            guard path.hasPrefix(root) else { return nil }
            return path.dropFirst(root.count).split(separator: "/").first.map(String.init)
        })
        for name in names where name != key && !inUse.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The executable path of every process we can see.
    private static func runningExecutables() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(found)).compactMap { pid in
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
    }
}
#endif
