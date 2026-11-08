import AgTermCore
import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// "Keep Mac awake while agents run" (Settings → Agents, agterm menu). While an agent tab on this
/// Mac is working, an IOPMAssertion stops idle sleep; "Also when the lid is closed" also runs the
/// root helper (`ClosedLidHelper`), which holds `pmset disablesleep 1` until agterm exits or crashes.
/// Both are let go of as soon as no agent is working.
final class KeepAwake: NSObject, NSMenuItemValidation {
    static let shared = KeepAwake()
    static let enabledKey = "keepAwakeWhileAgentsRun"
    static let closedLidKey = "keepAwakeClosedLid"
    /// Posted on the main queue when `helperInstalled` changes.
    static let helperChanged = Notification.Name("agtermKeepAwakeHelperChanged")

    private var plan = KeepAwakePlan()
    private var assertion: IOPMAssertionID?
    private var lidHelper: Process?
    private var lidRetryAfter = Date.distantPast
    /// Root-owned helper and sudoers rule in place, and sudo runs it without a password.
    private(set) var helperInstalled = false {
        didSet { if helperInstalled != oldValue { NotificationCenter.default.post(name: Self.helperChanged, object: nil) } }
    }

    private var defaults: UserDefaults { .standard }
    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var closedLid: Bool { defaults.bool(forKey: Self.closedLidKey) }

    /// At launch: finds the helper and clears a flag a crashed run might have left on.
    func start() {
        DispatchQueue.global(qos: .utility).async {
            let installed = Self.checkHelper()
            if installed { _ = Self.runHelper(["disable"]) }
            DispatchQueue.main.async { self.helperInstalled = installed }
        }
    }

    /// Called on every status tick with whether an agent tab on this Mac is in a turn.
    func update(agentsBusy: Bool) {
        // After the helper stopped on its own, wait a little before starting it again.
        let helperReady = helperInstalled && Date() >= lidRetryAfter
        let lid = enabled && closedLid && helperReady && agentsBusy
        // The power source is only asked about while it matters.
        let inputs = KeepAwakePlan.Inputs(enabled: enabled, closedLid: closedLid, helperInstalled: helperReady,
                                          agentsBusy: agentsBusy, onBattery: lid && Self.onBattery)
        plan.update(inputs).forEach(perform)
    }

    /// When agterm quits. The helper would notice anyway, within two seconds.
    func stop() {
        plan.releaseAll().forEach(perform)
    }

    private func perform(_ action: KeepAwakePlan.Action) {
        switch action {
        case .holdIdleSleep:
            var id = IOPMAssertionID(0)
            let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                      IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                      "agterm: agents are working" as CFString, &id)
            assertion = created == kIOReturnSuccess ? id : nil
        case .releaseIdleSleep:
            if let assertion { IOPMAssertionRelease(assertion) }
            assertion = nil
        case .holdLidSleep:
            startLidHelper()
        case .releaseLidSleep:
            let helper = lidHelper
            lidHelper = nil
            // sudo passes SIGTERM on; the script's trap turns sleep back on.
            helper?.terminate()
        case .warnBattery:
            Notifier.shared.post(title: "Keeping your Mac awake on battery",
                                 body: "Agents are working, so your Mac stays awake even with the lid closed. "
                                     + "It drains the battery and can get hot in a bag. It sleeps again when they finish.",
                                 tabID: "keep-awake")
        }
    }

    private func startLidHelper() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", ClosedLidHelper.path, "enable-until", String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                // Ended on its own: try again shortly, if the helper is still installed and wanted.
                guard let self, self.lidHelper === ended else { return }
                self.lidHelperStopped()
            }
        }
        do {
            try process.run()
            lidHelper = process
        } catch {
            NSLog("agterm: closed-lid helper didn't start: \(error)")
            lidHelperStopped()
        }
    }

    private func lidHelperStopped() {
        lidHelper = nil
        plan.lidHoldEnded()
        lidRetryAfter = Date().addingTimeInterval(10)
        recheckHelper()
    }

    // MARK: Helper install

    func recheckHelper() {
        DispatchQueue.global(qos: .utility).async {
            let installed = Self.checkHelper()
            DispatchQueue.main.async { self.helperInstalled = installed }
        }
    }

    /// Asks for an administrator's password, then installs the helper. `done` runs on the main queue
    /// with an error message, "" if you cancelled, or nil once sudo runs the helper.
    func installHelper(done: @escaping (String?) -> Void) {
        guard let script = ClosedLidHelper.installScript(user: NSUserName()) else {
            return done("agterm can't add a sudoers rule for the user name \"\(NSUserName())\".")
        }
        runAsAdmin(script, prompt: "agterm needs an administrator to let it keep your Mac awake with the lid closed.") { error in
            let installed = error == nil && Self.checkHelper()
            DispatchQueue.main.async {
                self.helperInstalled = installed
                if let error { return done(error) }
                done(installed ? nil : "The helper was installed, but sudo won't run it without a password. Check \(ClosedLidHelper.sudoersPath).")
            }
        }
    }

    func uninstallHelper(done: @escaping (String?) -> Void) {
        // Stopped first so the files can go; if you cancel, the next tick starts it again.
        let helper = lidHelper
        lidHelper = nil
        plan.lidHoldEnded()
        helper?.terminate()
        runAsAdmin(ClosedLidHelper.uninstallScript, prompt: "agterm needs an administrator to remove its closed-lid helper.") { error in
            let installed = Self.checkHelper()
            DispatchQueue.main.async {
                self.helperInstalled = installed
                done(error)
            }
        }
    }

    /// Runs `script` with /bin/sh as root after the system's password or Touch ID prompt, off the main thread.
    /// `done` runs on that background queue with nil, an error message, or "" if you cancelled.
    private func runAsAdmin(_ script: String, prompt: String, done: @escaping (String?) -> Void) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        let source = "do shell script \(quoted(script)) with prompt \(quoted(prompt)) with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return done("Couldn't ask for an administrator: \(error.localizedDescription)") }
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return done(nil) }
            // -128: you pressed Cancel, which needs no message.
            done(message.contains("-128") ? "" : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Checks (any thread)

    /// Both files are in place and root-owned, and sudo runs the helper without asking.
    private static func checkHelper() -> Bool {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: ClosedLidHelper.path),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o022 == 0,
              files.fileExists(atPath: ClosedLidHelper.sudoersPath) else { return false }
        return runHelper(["status"]) == 0
    }

    @discardableResult
    private static func runHelper(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", ClosedLidHelper.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    // MARK: Menu

    @objc func toggleEnabled(_ sender: Any?) {
        defaults.set(!enabled, forKey: Self.enabledKey)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleEnabled(_:)) { menuItem.state = enabled ? .on : .off }
        return true
    }
}
