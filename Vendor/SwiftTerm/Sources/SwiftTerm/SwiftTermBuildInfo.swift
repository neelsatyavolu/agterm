// Upstream generates this file with a build plugin that reads git; the vendored copy pins it.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v1.20.0"
    public static let commit: String? = "5d14406844143538cd8f8851d2d8a67c1fe443e5"
    /// Patched by agterm (see Vendor/SwiftTerm/README.md).
    public static let hasUncommittedChanges: Bool? = true

    public static let version: String = {
        let base = tag ?? commit.map { String($0.prefix(12)) } ?? "unknown"
        return hasUncommittedChanges == true ? "\(base)-modified" : base
    }()
}
