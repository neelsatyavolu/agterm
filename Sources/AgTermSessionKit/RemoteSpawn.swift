import AgTermCore
import Foundation

/// A spawn that comes through the gateway describes the Mac's tab: its shell and its folder.
/// This machine starts its own login shell instead, with its own environment, keeping only the
/// terminal settings and tab id the client sent (never the Mac's PATH, keys or tokens).
enum RemoteSpawn {
    struct Account: Equatable {
        var user: String
        var home: String
        var shell: String
        var path: String

        /// The user the helper runs as, and the PATH it was started with.
        static var current: Account {
            let entry = getpwuid(getuid())?.pointee
            let user = entry.map { String(cString: $0.pw_name) } ?? "user"
            let home = entry.map { String(cString: $0.pw_dir) } ?? "/"
            let shell = entry.map { String(cString: $0.pw_shell) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh"
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            return Account(user: user, home: home, shell: shell, path: path)
        }
    }

    private static let clientKeys: Set<String> = ["TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LANG", "AGTERM_TAB_ID"]

    static func localize(_ request: SpawnRequest, for account: Account,
                         isDirectory: (String) -> Bool = RemoteSpawn.isDirectory) -> SpawnRequest {
        var env = ["HOME=\(account.home)", "USER=\(account.user)", "LOGNAME=\(account.user)",
                   "SHELL=\(account.shell)", "PATH=\(account.path)"]
        env += request.env.filter { entry in
            let key = entry.prefix { $0 != "=" }
            return clientKeys.contains(String(key)) || key.hasPrefix("LC_")
        }
        let name = (account.shell as NSString).lastPathComponent
        let cwd = request.cwd.hasPrefix("/") && isDirectory(request.cwd) ? request.cwd : account.home
        return SpawnRequest(executable: account.shell, argv: ["-" + name], env: env, cwd: cwd,
                            cols: request.cols, rows: request.rows)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
