import Foundation

/// How `agterm-remote` copies a project to a Windows PC, which has no rsync: the PC's
/// agterm-worker lists what its copy holds (`manifest`), this Mac works out what differs, sends
/// those files as a tar (`receive`) and names the ones to remove (`delete`). Files match when
/// size and modification time (whole seconds, what tar keeps) are equal, rsync's quick check.
public enum WindowsSync {
    /// The worker's own commands start with this word.
    public static let worker = "agterm-worker"

    public struct Entry: Equatable {
        public var size: Int64
        public var mtime: Int64

        public init(size: Int64, mtime: Int64) {
            self.size = size
            self.mtime = mtime
        }
    }

    public struct Plan: Equatable {
        /// Relative paths to send, sorted.
        public var send: [String]
        /// Relative paths to remove there, sorted.
        public var delete: [String]
    }

    /// `manifest`'s output: `path\tsize\tmtime` records, each ending in NUL. Malformed records are skipped.
    public static func parseManifest(_ data: Data) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for record in data.split(separator: 0) {
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let size = Int64(fields[fields.count - 2]), let mtime = Int64(fields[fields.count - 1]) else { continue }
            // A tab in a file name stays with the path.
            let path = fields.dropLast(2).joined(separator: "\t")
            guard !path.isEmpty else { continue }
            entries[path] = Entry(size: size, mtime: mtime)
        }
        return entries
    }

    /// What to send and remove so the PC's copy matches `local`. Paths there that aren't here
    /// are removed unless `keepThere` says to leave them (git-ignored here: what the PC built).
    public static func plan(local: [String: Entry], remote: [String: Entry], keepThere: (String) -> Bool) -> Plan {
        let send = local.filter { remote[$0.key] != $0.value }.map(\.key).sorted()
        let delete = remote.keys.filter { local[$0] == nil && !keepThere($0) }.sorted()
        return Plan(send: send, delete: delete)
    }

    /// Whether any folder in `path` is one of `excluded` (node_modules and the like).
    public static func isExcluded(_ path: String, excluded: [String]) -> Bool {
        path.split(separator: "/").dropLast().contains { excluded.contains(String($0)) }
    }

    /// `--skip <name>` for each excluded folder, for `manifest` and `changed`.
    public static func skipArguments(_ excluded: [String]) -> [String] {
        excluded.flatMap { ["--skip", $0] }
    }

    /// NUL-separated paths, as `delete` and `pack` read them.
    public static func pathList(_ paths: [String]) -> Data {
        Data(paths.map { $0 + "\0" }.joined().utf8)
    }

    /// The worker's `info` reply.
    public struct Info: Codable, Equatable {
        public var version: String
        public var system: String
        /// With forward slashes (`C:/Users/neel`).
        public var home: String
        /// "pwsh" (PowerShell 7) or "powershell" (Windows PowerShell 5.1).
        public var shell: String
    }

    public static func parseInfo(_ text: String) -> Info? {
        try? JSONDecoder().decode(Info.self, from: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }
}
