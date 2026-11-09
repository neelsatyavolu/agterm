import Foundation

/// The composer's `@` menu: the file or folder path being typed after an `@`, the files in the
/// tab's folder that match it, and the text a chosen one leaves in the box. Claude Code, Codex
/// and Grok all read `@path` in a message as a file to look at.
public enum FileMention {
    /// The most paths a folder lists; past this the menu only searches the first ones found.
    public static let maxFiles = 20_000
    /// The most matches the menu ranks and keeps.
    static let maxResults = 50
    /// Folders a walk outside a git repository skips.
    static let skipped: Set<String> = ["node_modules", ".build", "build", "dist", "target", "DerivedData", "Pods", "vendor"]

    /// The `@` word ending at the caret: what follows the `@`, and where the `@` is (in UTF-16
    /// offsets, as the text view counts). Nil when the caret isn't in an `@` word.
    public static func query(_ text: String, caret: Int) -> (query: String, start: Int)? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        var start = caret
        while start > 0 {
            let unit = ns.character(at: start - 1)
            if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        let word = ns.substring(with: NSRange(location: start, length: caret - start))
        guard word.hasPrefix("@"), !word.dropFirst().contains("@"), !word.contains("\"") else { return nil }
        return (String(word.dropFirst()), start)
    }

    /// `@path ` for a chosen path, quoted the way Claude Code writes one with spaces. A folder
    /// stays open (`@Sources/`), so typing goes on to list what's in it.
    public static func completion(_ path: String) -> String {
        if path.contains(" ") { return "@\"\(path)\" " }
        return path.hasSuffix("/") ? "@\(path)" : "@\(path) "
    }

    /// Paths for `query`, best first: an empty query lists the folder's top level, then
    /// everything; otherwise fuzzy matches, where a file name that starts with the query wins.
    public static func matches(_ query: String, in paths: [String]) -> [String] {
        guard !query.isEmpty else {
            let top = paths.filter { !$0.dropLast().contains("/") }
            return Array((top + paths.filter { $0.dropLast().contains("/") }).prefix(maxResults))
        }
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        // A cheap in-order check first, so the scoring only runs on paths that can match.
        let candidates = paths.filter { contains(needle, in: $0.lowercased()) }
            .sorted { $0.count < $1.count }.prefix(3000)
        let lower = query.lowercased()
        let named = candidates.filter { name(of: $0).lowercased().hasPrefix(lower) }
        let rest = FuzzyMatch.rank(query, candidates.filter { !name(of: $0).lowercased().hasPrefix(lower) }) { $0 }.map(\.item)
        return Array((named + rest).prefix(maxResults))
    }

    /// The files under `folder`, relative to it, with each folder they're in listed once as
    /// `dir/`. A git repository lists what git tracks plus untracked files it doesn't ignore;
    /// elsewhere hidden files and build folders are left out.
    public static func files(in folder: String) -> [String] {
        var isDir: ObjCBool = false
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return [] }
        let files = gitFiles(in: folder) ?? walk(folder)
        var folders: [String] = [], seen = Set<String>()
        for file in files {
            var parts = file.split(separator: "/").dropLast()
            while !parts.isEmpty {
                let dir = parts.joined(separator: "/") + "/"
                if !seen.insert(dir).inserted { break }
                folders.append(dir)
                parts = parts.dropLast()
            }
        }
        return Array((folders.sorted() + files).prefix(maxFiles))
    }

    private static func name(of path: String) -> Substring {
        let trimmed = path.hasSuffix("/") ? path.dropLast() : Substring(path)
        return trimmed.split(separator: "/").last ?? trimmed
    }

    private static func contains(_ needle: [Character], in text: String) -> Bool {
        var index = needle.startIndex
        for char in text where index < needle.endIndex && char == needle[index] { index += 1 }
        return index == needle.endIndex
    }

    private static func gitFiles(in folder: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        // ls-files lists a file once per merge stage while a conflict is open.
        var seen = Set<String>()
        return Array(lines.filter { seen.insert($0).inserted }.prefix(maxFiles))
    }

    private static func walk(_ folder: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
        var out: [String] = []
        while let path = walker.nextObject() as? String, out.count < maxFiles {
            let name = (path as NSString).lastPathComponent
            let isDir = walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            if name.hasPrefix(".") || (isDir && skipped.contains(name)) {
                if isDir { walker.skipDescendants() }
                continue
            }
            if !isDir { out.append(path) }
        }
        return out.sorted()
    }
}
