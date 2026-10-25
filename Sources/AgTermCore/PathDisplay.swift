import Foundation

public enum PathDisplay {
    /// The folder name shown on a tab: last path component, `~` for home.
    public static func folder(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}
