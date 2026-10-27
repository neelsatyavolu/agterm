import Foundation

/// Where the helper's socket lives: one per state directory, so debug and release builds
/// (and tests) each get their own helper.
public enum SessionPaths {
    /// `/tmp/agterm-<uid>`; short, because a Unix socket path is limited to 104 bytes.
    public static var directory: String { "/tmp/agterm-\(getuid())" }

    /// `/tmp/agterm-<uid>/<fnv1a32(stateDir) as 8 lowercase hex>.sock`
    public static func socket(stateDir: String) -> String {
        directory + "/" + String(format: "%08x", fnv1a32(stateDir)) + ".sock"
    }

    /// `/tmp/agterm-<uid>/grok-<fnv1a32(home) as 8 lowercase hex>.sock`: the Grok leader socket
    /// for a login agterm keeps. Grok adds `.daemon` beside it, so it must stay short too.
    public static func grokLeader(home: String) -> String {
        directory + "/grok-" + String(format: "%08x", fnv1a32(home)) + ".sock"
    }

    /// `co.xanom.agterm.sessions.<fnv1a32 of the arguments as 8 lowercase hex>`: the launchd label of
    /// a helper started with `arguments`. A loaded job's arguments never change, so a label that
    /// is already loaded can simply be started again.
    public static func helperJobLabel(arguments: [String]) -> String {
        "co.xanom.agterm.sessions." + String(format: "%08x", fnv1a32(arguments.joined(separator: "\0")))
    }

    static func fnv1a32(_ text: String) -> UInt32 {
        text.utf8.reduce(0x811c_9dc5 as UInt32) { ($0 ^ UInt32($1)) &* 0x0100_0193 }
    }

    /// Creates `path` as a 0700 directory if missing, then checks it with `verifyDirectory`.
    public static func prepareDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw POSIXError.current }
        try verifyDirectory(path)
    }

    /// Refuses `path` unless it is a real directory (not a symlink) owned by us with no group
    /// or other access: anyone else able to write there could stand in for the helper.
    public static func verifyDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw SessionPathError.untrustedDirectory(path)
        }
    }
}

public enum SessionPathError: Error, Equatable {
    /// The socket's directory is a symlink, not ours, or open to group or others.
    case untrustedDirectory(String)
}

extension POSIXError {
    /// The error in `errno`.
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
