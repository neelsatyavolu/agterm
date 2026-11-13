import Foundation

/// Tabs you closed in a window, newest last, for Shell → Reopen Closed Tab. Each is saved the
/// way a quit saves it (folder, history, the agent's resume command), without its shell.
public final class ClosedTabs {
    /// How many closed tabs are kept; older ones drop off.
    public static let limit = 10
    public private(set) var tabs: [SavedTab] = []

    public init() {}

    public func push(_ tab: SavedTab) {
        var tab = tab
        // Its shell has ended; reopening starts a new one.
        tab.sessionID = nil
        tabs = Array((tabs + [tab]).suffix(Self.limit))
    }

    /// The tab closed last, removed from the list.
    public func popLast() -> SavedTab? {
        tabs.popLast()
    }

    /// The tab at `index` in `tabs`, removed from the list.
    public func take(at index: Int) -> SavedTab? {
        guard tabs.indices.contains(index) else { return nil }
        return tabs.remove(at: index)
    }

    public var isEmpty: Bool { tabs.isEmpty }

    /// How Shell → Recently Closed lists a tab: its name, or the agent it would resume, or
    /// "Shell", then its folder. "Claude Code — agterm".
    public static func title(_ tab: SavedTab) -> String {
        let folder = (tab.cwd as NSString).lastPathComponent
        let words = (tab.resume ?? "").split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init)
        let agent = words.lazy.compactMap { word in AgentKind.all.first { $0.commands.contains(word) } }.first
        let what = tab.name ?? agent?.title ?? "Shell"
        return folder.isEmpty || folder == "/" ? what : "\(what) — \(folder)"
    }
}
