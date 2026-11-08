import Foundation

/// What "Keep Mac awake while agents run" should hold right now, and what changed since last time.
/// The app feeds it every status tick and carries out the actions; nothing here touches the system.
public struct KeepAwakePlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Take or let go of the IOPMAssertion that stops idle sleep.
        case holdIdleSleep, releaseIdleSleep
        /// Start or stop the closed-lid helper (`pmset disablesleep 1` until agterm exits).
        case holdLidSleep, releaseLidSleep
        /// The lid hold is on while the Mac runs on battery: tell the user once per hold.
        case warnBattery
    }

    public struct Inputs: Equatable, Sendable {
        public var enabled: Bool
        public var closedLid: Bool
        public var helperInstalled: Bool
        /// An agent tab is in a turn.
        public var agentsBusy: Bool
        public var onBattery: Bool

        public init(enabled: Bool, closedLid: Bool, helperInstalled: Bool, agentsBusy: Bool, onBattery: Bool) {
            self.enabled = enabled
            self.closedLid = closedLid
            self.helperInstalled = helperInstalled
            self.agentsBusy = agentsBusy
            self.onBattery = onBattery
        }
    }

    public private(set) var holdingIdle = false
    public private(set) var holdingLid = false
    private var warnedThisHold = false

    public init() {}

    /// The actions that bring what's held in line with `inputs`, releases first.
    public mutating func update(_ inputs: Inputs) -> [Action] {
        let wantIdle = inputs.enabled && inputs.agentsBusy
        let wantLid = wantIdle && inputs.closedLid && inputs.helperInstalled
        var actions: [Action] = []
        if holdingLid, !wantLid { actions.append(.releaseLidSleep) }
        if holdingIdle, !wantIdle { actions.append(.releaseIdleSleep) }
        if !holdingIdle, wantIdle { actions.append(.holdIdleSleep) }
        if !holdingLid, wantLid { actions.append(.holdLidSleep) }
        holdingIdle = wantIdle
        holdingLid = wantLid
        // A new hold starts when agents start working again or the lid option is turned back on,
        // not when a stopped helper is restarted.
        if !wantIdle || !inputs.closedLid { warnedThisHold = false }
        if wantLid, inputs.onBattery, !warnedThisHold {
            warnedThisHold = true
            actions.append(.warnBattery)
        }
        return actions
    }

    /// The helper stopped without being asked to (or was stopped for an uninstall): the next
    /// `update` starts it again if it's still wanted. The battery warning isn't repeated.
    public mutating func lidHoldEnded() {
        holdingLid = false
    }

    /// Lets go of everything, as when agterm quits.
    public mutating func releaseAll() -> [Action] {
        update(Inputs(enabled: false, closedLid: false, helperInstalled: false, agentsBusy: false, onBattery: false))
    }
}

/// The root-owned helper behind "Also when the lid is closed", the way agmux does it: a short
/// script in /Library/PrivilegedHelperTools that sets `pmset disablesleep 1` until agterm's process
/// exits, plus a sudoers rule that lets the current user run only that file, only with these arguments.
public enum ClosedLidHelper {
    public static let path = "/Library/PrivilegedHelperTools/co.xanom.agterm.closed-lid"
    /// sudo skips files in sudoers.d whose names contain a dot, so this one has none.
    public static let sudoersPath = "/etc/sudoers.d/agterm-closed-lid"
    /// agmux's helper sets the same system flag. agterm's leaves it on while agmux's holds it, and
    /// sets it again within two seconds if agmux clears it.
    public static let agmuxPath = "/Library/PrivilegedHelperTools/com.agmux.closed-lid"

    /// Bash, run as root by sudo. Takes no input but its arguments, which it checks strictly.
    public static let script = #"""
        #!/bin/bash
        # co.xanom.agterm.closed-lid: keeps the Mac awake with the lid closed while agterm's agents run.
        # Installed root-owned by agterm (Settings > Agents); the sudoers rule in /etc/sudoers.d/agterm-closed-lid
        # lets its user run only this file. Usage: enable-until <pid> | disable | status
        set -euo pipefail
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        PMSET=/usr/bin/pmset

        sleep_disabled() { "$PMSET" -g | /usr/bin/grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1'; }

        # Each running enable-until registers its pid here (root-only), under a lock, so two of them
        # stopping at once can't each leave the flag on for the other.
        REG=/var/run/agterm-closed-lid
        LOCK=/var/run/agterm-closed-lid.lock

        lock() {
          local tries=0
          # A lock left by a killed helper is taken over after about 5 seconds.
          until /bin/mkdir "$LOCK" 2>/dev/null; do
            tries=$((tries + 1))
            if [ "$tries" -ge 50 ]; then /bin/rm -rf "$LOCK"; tries=0; fi
            /bin/sleep 0.1
          done
        }
        unlock() { /bin/rmdir "$LOCK" 2>/dev/null || true; }

        # Another of agterm's helpers still running; stale entries are removed.
        ours_holding() {
          local entry pid found=1
          for entry in "$REG"/*; do
            [ -e "$entry" ] || continue
            pid="${entry##*/}"
            if [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$pid" 2>/dev/null; then found=0; else /bin/rm -f "$entry"; fi
          done
          return "$found"
        }

        # agmux's helper (run by root through sudo) still holds the flag.
        agmux_holding() {
          /bin/ps -axo uid=,command= | /usr/bin/awk '
            $1 == 0 && $2 == "/bin/bash" && $3 == "/Library/PrivilegedHelperTools/com.agmux.closed-lid" && $4 == "enable-until" { found = 1 }
            END { exit found ? 0 : 1 }'
        }

        clear_flag() {
          lock
          /bin/rm -f "$REG/$$"
          ours_holding || agmux_holding || "$PMSET" -a disablesleep 0 || true
          unlock
        }

        usage() { echo "usage: $0 enable-until <pid> | disable | status" >&2; exit 2; }

        case "${1:-}" in
          enable-until)
            [ "$#" -eq 2 ] || usage
            pid="$2"
            [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || usage
            trap clear_flag EXIT
            trap 'exit 0' INT TERM HUP
            lock
            /bin/mkdir -p -m 700 "$REG"
            : > "$REG/$$"
            unlock
            while /bin/kill -0 "$pid" 2>/dev/null; do
              # Set again if something else (an agmux quit) cleared it.
              sleep_disabled || "$PMSET" -a disablesleep 1
              /bin/sleep 2
            done
            ;;
          disable)
            [ "$#" -eq 1 ] || usage
            clear_flag
            ;;
          status)
            [ "$#" -eq 1 ] || usage
            if sleep_disabled; then echo active; else echo inactive; fi
            ;;
          *) usage ;;
        esac
        """#

    /// A macOS short name sudoers can hold as is; never root.
    public static func isValidUser(_ user: String) -> Bool {
        guard user != "root", (1...64).contains(user.count) else { return false }
        return user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    /// The sudoers rule: `user` may run the helper as root with exactly these arguments, no password.
    public static func sudoers(user: String) -> String? {
        guard isValidUser(user) else { return nil }
        return """
            # Managed by agterm: closed-lid keep-awake (pmset disablesleep). Remove in agterm's Settings > Agents.
            \(user) ALL=(root) NOPASSWD: \(path) enable-until *, \(path) disable, \(path) status

            """
    }

    /// The /bin/sh script agterm runs once with administrator privileges. File contents travel
    /// base64-encoded inside it and are written by root into root-owned folders, so there's no
    /// file the user could swap in between. The sudoers file is checked with visudo before it's moved in.
    public static func installScript(user: String) -> String? {
        guard let rules = sudoers(user: user) else { return nil }
        let helper = Data(script.utf8).base64EncodedString()
        let sudo = Data(rules.utf8).base64EncodedString()
        return """
            set -eu
            umask 077
            /bin/mkdir -p /Library/PrivilegedHelperTools /etc/sudoers.d
            T=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.agterm-closed-lid.XXXXXX)
            S=$(/usr/bin/mktemp /etc/sudoers.d/.agterm-closed-lid.XXXXXX)
            trap '/bin/rm -f "$T" "$S"' EXIT
            /bin/echo '\(helper)' | /usr/bin/base64 -D > "$T"
            /usr/sbin/chown root:wheel "$T"
            /bin/chmod 755 "$T"
            /bin/echo '\(sudo)' | /usr/bin/base64 -D > "$S"
            /usr/sbin/chown root:wheel "$S"
            /bin/chmod 440 "$S"
            /usr/sbin/visudo -cqf "$S"
            /bin/mv -f "$T" '\(path)'
            /bin/mv -f "$S" '\(sudoersPath)'
            """
    }

    /// Clears the flag (unless agmux still holds it) and removes both files.
    public static let uninstallScript = """
        set -u
        [ -x '\(path)' ] && '\(path)' disable
        /bin/rm -f '\(path)' '\(sudoersPath)'
        """
}
