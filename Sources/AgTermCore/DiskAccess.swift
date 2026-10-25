import Foundation

/// Full Disk Access can't be queried directly; it shows up as whether TCC-protected files open.
public enum DiskAccess: Equatable, Sendable {
    case granted
    case denied
    /// No probe was conclusive (e.g. none of the protected files exist).
    case unknown

    /// Files only readable with Full Disk Access.
    public static let probePaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari",
        "Library/Safari/Bookmarks.plist",
        "Library/Mail",
    ]

    /// `results` holds 0 for each probe that opened and the errno for each that didn't.
    public static func decide(_ results: [Int32]) -> DiskAccess {
        if results.contains(0) { return .granted }
        if results.contains(where: { $0 == EPERM || $0 == EACCES }) { return .denied }
        return .unknown
    }

    /// Opens each probe path under `home` read-only and decides.
    public static func check(home: String = NSHomeDirectory()) -> DiskAccess {
        decide(probePaths.map { path in
            let fd = open((home as NSString).appendingPathComponent(path), O_RDONLY)
            if fd >= 0 {
                close(fd)
                return 0
            }
            return errno
        })
    }
}
