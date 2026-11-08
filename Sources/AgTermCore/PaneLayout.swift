import Foundation

/// Which way a split divides its space.
public enum PaneAxis: String, Codable, Sendable {
    /// Side by side, divided by a vertical line (Split Right).
    case columns
    /// One above the other, divided by a horizontal line (Split Down).
    case rows
}

/// A rect in a top-left-origin space, so the layout builds without CoreGraphics (on Linux too).
public struct PaneRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// Moving focus from one pane to the next one over.
public enum PaneDirection: Sendable {
    case left, right, up, down
}

/// How a tab's panes are arranged: a pane, or a split of two arrangements. Each pane is a
/// shell, named by its tab ID. Rects are in a top-left-origin space (y grows downward).
public indirect enum PaneNode: Codable, Equatable, Sendable {
    case pane(String)
    /// `ratio` is the share of the space the first side gets, 0...1.
    case split(PaneAxis, ratio: Double, PaneNode, PaneNode)

    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    /// The panes, left to right and top to bottom.
    public var panes: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let a, let b): a.panes + b.panes
        }
    }

    public func contains(_ id: String) -> Bool { panes.contains(id) }

    /// `id`'s pane split in two, `id` first and `new` beside or below it, half each.
    public func splitting(_ id: String, with new: String, axis: PaneAxis) -> PaneNode {
        switch self {
        case .pane(let current):
            current == id ? .split(axis, ratio: 0.5, .pane(id), .pane(new)) : self
        case .split(let ax, let ratio, let a, let b):
            .split(ax, ratio: ratio, a.splitting(id, with: new, axis: axis), b.splitting(id, with: new, axis: axis))
        }
    }

    /// Without `id`'s pane, its neighbor taking the space; nil when it was the only pane.
    public func removing(_ id: String) -> PaneNode? {
        switch self {
        case .pane(let current):
            return current == id ? nil : self
        case .split(let ax, let ratio, let a, let b):
            switch (a.removing(id), b.removing(id)) {
            case (nil, let rest), (let rest, nil): return rest
            case (let a?, let b?): return .split(ax, ratio: ratio, a, b)
            }
        }
    }

    /// Only the panes in `ids`; nil when none of them are left.
    public func keeping(_ ids: Set<String>) -> PaneNode? {
        panes.filter { !ids.contains($0) }.reduce(Optional(self)) { node, gone in node?.removing(gone) }
    }

    /// `old`'s pane now shows `new`.
    public func replacing(_ old: String, with new: String) -> PaneNode {
        switch self {
        case .pane(let id): .pane(id == old ? new : id)
        case .split(let ax, let ratio, let a, let b): .split(ax, ratio: ratio, a.replacing(old, with: new), b.replacing(old, with: new))
        }
    }

    // MARK: Geometry

    /// Each pane's rect in `rect`, with `gap` points between neighbors; splits round to whole points.
    public func frames(in rect: PaneRect, gap: Double) -> [String: PaneRect] {
        switch self {
        case .pane(let id):
            return [id: rect]
        case .split(let axis, let ratio, let a, let b):
            let (first, second, _) = Self.divide(rect, axis: axis, ratio: ratio, gap: gap)
            return a.frames(in: first, gap: gap).merging(b.frames(in: second, gap: gap)) { $1 }
        }
    }

    /// A split's divider: the gap between its two sides, and how to find it again (`path`:
    /// 0 for the first side, 1 for the second, from the top).
    public struct Divider: Equatable, Sendable {
        public var path: [Int]
        public var axis: PaneAxis
        public var rect: PaneRect
        /// The space the split shares out, for turning a drag into a ratio.
        public var span: PaneRect
    }

    public func dividers(in rect: PaneRect, gap: Double, path: [Int] = []) -> [Divider] {
        guard case .split(let axis, let ratio, let a, let b) = self else { return [] }
        let (first, second, line) = Self.divide(rect, axis: axis, ratio: ratio, gap: gap)
        return [Divider(path: path, axis: axis, rect: line, span: rect)]
            + a.dividers(in: first, gap: gap, path: path + [0]) + b.dividers(in: second, gap: gap, path: path + [1])
    }

    /// The split at `path` with its first side given `ratio` of the space (kept in `ratioRange`).
    public func settingRatio(_ ratio: Double, at path: [Int]) -> PaneNode {
        guard case .split(let ax, let current, let a, let b) = self else { return self }
        guard let step = path.first else {
            let clamped = ratio.isFinite ? min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound) : current
            return .split(ax, ratio: clamped, a, b)
        }
        let rest = Array(path.dropFirst())
        return step == 0 ? .split(ax, ratio: current, a.settingRatio(ratio, at: rest), b)
            : .split(ax, ratio: current, a, b.settingRatio(ratio, at: rest))
    }

    /// The pane next to `id` in `direction`: of those that line up with it on the other axis,
    /// the closest. Nil at the edge.
    public func neighbor(of id: String, _ direction: PaneDirection, in rect: PaneRect) -> String? {
        let frames = frames(in: rect, gap: 2)
        guard let from = frames[id] else { return nil }
        let candidates = frames.filter { (other: String, frame: PaneRect) -> Bool in
            guard other != id else { return false }
            switch direction {
            case .left: return frame.maxX <= from.minX && Self.overlaps(frame.minY...frame.maxY, from.minY...from.maxY)
            case .right: return frame.minX >= from.maxX && Self.overlaps(frame.minY...frame.maxY, from.minY...from.maxY)
            case .up: return frame.maxY <= from.minY && Self.overlaps(frame.minX...frame.maxX, from.minX...from.maxX)
            case .down: return frame.minY >= from.maxY && Self.overlaps(frame.minX...frame.maxX, from.minX...from.maxX)
            }
        }
        func distance(_ frame: PaneRect) -> Double {
            switch direction {
            case .left: from.minX - frame.maxX
            case .right: frame.minX - from.maxX
            case .up: from.minY - frame.maxY
            case .down: frame.minY - from.maxY
            }
        }
        // Closest first; among equals, the one nearest the top-left, so the answer is stable.
        return candidates.min { a, b in
            let (da, db) = (distance(a.value), distance(b.value))
            if da != db { return da < db }
            return (a.value.minY, a.value.minX) < (b.value.minY, b.value.minX)
        }?.key
    }

    private static func overlaps(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Bool {
        min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound) > 1
    }

    private static func divide(_ rect: PaneRect, axis: PaneAxis, ratio: Double, gap: Double) -> (PaneRect, PaneRect, PaneRect) {
        switch axis {
        case .columns:
            let room = max(0, rect.width - gap)
            let firstWidth = (room * ratio).rounded()
            let first = PaneRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let line = PaneRect(x: first.maxX, y: rect.minY, width: gap, height: rect.height)
            let second = PaneRect(x: line.maxX, y: rect.minY, width: max(0, rect.maxX - line.maxX), height: rect.height)
            return (first, second, line)
        case .rows:
            let room = max(0, rect.height - gap)
            let firstHeight = (room * ratio).rounded()
            let first = PaneRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let line = PaneRect(x: rect.minX, y: first.maxY, width: rect.width, height: gap)
            let second = PaneRect(x: rect.minX, y: line.maxY, width: rect.width, height: max(0, rect.maxY - line.maxY))
            return (first, second, line)
        }
    }
}

/// A tab's panes as saved: their arrangement and which one had focus.
public struct SavedPaneGroup: Codable, Equatable, Sendable {
    public var layout: PaneNode
    public var focused: String

    public init(layout: PaneNode, focused: String) {
        self.layout = layout
        self.focused = focused
    }

    /// The saved tabs (panes) gathered into tabs again: saved groups first-come in tab order,
    /// each cut down to the panes that came back, and every other pane a tab of its own.
    /// `ids` is the panes that came back, in order.
    public static func regroup(_ ids: [String], saved: [SavedPaneGroup]) -> [SavedPaneGroup] {
        let present = Set(ids)
        var owner: [String: Int] = [:]
        var groups: [SavedPaneGroup] = []
        for group in saved {
            guard let layout = group.layout.keeping(present) else { continue }
            let panes = layout.panes.filter { owner[$0] == nil }
            guard let trimmed = layout.keeping(Set(panes)) else { continue }
            panes.forEach { owner[$0] = groups.count }
            groups.append(SavedPaneGroup(layout: trimmed, focused: trimmed.contains(group.focused) ? group.focused : panes[0]))
        }
        var result: [SavedPaneGroup] = []
        var placed = Set<Int>()
        for id in ids {
            if let index = owner[id] {
                if placed.insert(index).inserted { result.append(groups[index]) }
            } else {
                result.append(SavedPaneGroup(layout: .pane(id), focused: id))
            }
        }
        return result
    }
}
