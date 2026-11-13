/// Hands back one shared copy of each distinct string. Usage keeps hundreds of thousands of
/// events whose model, project and session repeat on every one; without this each event holds
/// its own copy of each.
public struct StringPool: Sendable {
    private var strings: Set<String> = []

    public init() {}

    public mutating func intern(_ string: String) -> String {
        if let shared = strings.firstIndex(of: string) { return strings[shared] }
        strings.insert(string)
        return string
    }

    public mutating func intern(_ string: Substring) -> String {
        intern(String(string))
    }
}
