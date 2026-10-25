import Foundation

public enum TabStatus: Equatable, Sendable {
    case idle
    case working
    /// Finished working while you were in another tab.
    case done
    /// Rang the bell while you were in another tab; usually a permission prompt.
    case waiting
    case exited

    public var label: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .waiting: "needs you"
        case .exited: "exited"
        }
    }
}

/// Raw observations about one tab. Dates are wall-clock times of the last event.
public struct StatusSignals: Equatable, Sendable {
    public var titleActivity: TitleActivity = .unknown
    public var lastOutput: Date?
    public var lastInput: Date?
    /// Shells and TUIs redraw when the window resizes; that output isn't work.
    public var lastResize: Date?
    public var lastBell: Date?
    /// When the title last changed. Spinners animate (Claude Code's ◐/◑ about once a second),
    /// so a spinner glyph that stopped changing is stale, not work.
    public var lastTitleChange: Date?
    /// Last Esc or Ctrl-C sent to the tab (by you or from the phone).
    public var lastInterrupt: Date?
    /// Last time the tab was judged to be working.
    public var lastWorking: Date?
    /// Last time the tab was on screen.
    public var lastSeen: Date?
    public var focused = false
    public var exited = false
    /// An agent's permission prompt or other choice is on screen (see `PermissionPrompt`).
    public var promptVisible = false

    public init() {}
}

public enum StatusRules {
    /// Output this recent counts as activity for programs with no title marker.
    public static let outputWindow: TimeInterval = 1.5
    /// Output this soon after a keystroke or resize is treated as echo, not work.
    public static let echoWindow: TimeInterval = 0.5
    /// A bell this close to the last working tick still counts as the latest event.
    public static let bellGrace: TimeInterval = 1.0
    /// A spinner title that hasn't changed for this long no longer counts as working.
    public static let spinnerWindow: TimeInterval = 3.0

    /// A bare Esc or a Ctrl-C: what stops an agent's turn.
    public static func isInterrupt(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b] || bytes.contains(0x03)
    }

    public static func status(_ s: StatusSignals, now: Date) -> TabStatus {
        if s.exited { return .exited }
        // Shown even on the tab you're looking at: the agent is stopped until you answer.
        if s.promptVisible { return .waiting }
        if isWorking(s, now: now) { return .working }
        let workSinceBell = s.lastWorking.map { $0.addingTimeInterval(-bellGrace) }
        if !s.focused, isAfterSeen(s.lastBell, s), isAfter(s.lastBell, workSinceBell) { return .waiting }
        // Work you stopped yourself isn't "finished while you were away".
        let stoppedByYou = s.lastInterrupt.map { interrupt in s.lastWorking.map { interrupt >= $0.addingTimeInterval(-bellGrace) } ?? true } ?? false
        if !s.focused, !stoppedByYou, isAfterSeen(s.lastWorking, s) { return .done }
        return .idle
    }

    public static func isWorking(_ s: StatusSignals, now: Date) -> Bool {
        if s.promptVisible { return false }
        switch s.titleActivity {
        case .working:
            // An interrupt ends the turn until the spinner moves again.
            if let interrupt = s.lastInterrupt, interrupt >= (s.lastTitleChange ?? .distantPast) { return false }
            guard let changed = s.lastTitleChange else { return true }
            return now.timeIntervalSince(changed) < spinnerWindow
        case .idle: return false
        case .unknown:
            guard let out = s.lastOutput, now.timeIntervalSince(out) < outputWindow else { return false }
            if let interrupt = s.lastInterrupt, interrupt >= out.addingTimeInterval(-echoWindow) { return false }
            // No keystroke yet means this is shell startup noise, not work you asked for.
            guard let input = s.lastInput else { return false }
            if let resize = s.lastResize, (0...echoWindow).contains(out.timeIntervalSince(resize)) { return false }
            return out.timeIntervalSince(input) > echoWindow
        }
    }

    /// True when `date` is set and later than `other` (or `other` is unset).
    private static func isAfter(_ date: Date?, _ other: Date?) -> Bool {
        guard let date else { return false }
        guard let other else { return true }
        return date > other
    }

    private static func isAfterSeen(_ date: Date?, _ s: StatusSignals) -> Bool {
        guard let date else { return false }
        guard let seen = s.lastSeen else { return true }
        return date > seen
    }
}
