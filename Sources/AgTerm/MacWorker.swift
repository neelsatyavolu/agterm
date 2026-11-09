import AgTermCore
import AgTermSessionKit
import Foundation
import SystemConfiguration

/// "Let my other Macs run tasks on this Mac" (Settings → Macs): a second sessions helper,
/// `agterm --sessions-helper --mac-listen`, run by launchd like the tabs' helper so it keeps
/// going after agterm quits and through a Force Quit. It advertises itself with Bonjour and
/// runs what paired Macs send as you, under ~/agterm-tasks. Starting and stopping happen in
/// order on `queue`, each acting on the setting as it is by then; the rest is any thread.
enum MacWorker {
    private static let queue = DispatchQueue(label: "agterm.mac-worker")

    static let enabledKey = "macWorkerEnabled"
    static let portKey = "macWorkerPort"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var port: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(saved) ? UInt16(saved) : MacLink.defaultPort
    }

    /// The Mac's name as Sharing settings has it ("Neel's Mac Studio"), at most 63 characters (Bonjour's limit).
    static var computerName: String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        return String(name.prefix(63))
    }

    /// Its `.local` name, which Bonjour resolves even when the service name doesn't.
    static var localHostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? ProcessInfo.processInfo.hostName
    }

    /// The code another Mac pastes to use this one.
    static var pairing: MacPairing {
        MacPairing(name: computerName, host: localHostName, port: port, secret: MacPairings.workerSecret)
    }

    static func setEnabled(_ on: Bool, then done: @escaping () -> Void = {}) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        update(then: done)
    }

    /// Starts or stops the job to match the setting. At launch, and after the code changes, a
    /// job whose settings are unchanged keeps running (and its tasks with it); otherwise it
    /// starts again with the new ones.
    static func update(then done: @escaping () -> Void = {}) {
        queue.async {
            isEnabled ? start() : stop()
            done()
        }
    }

    private static func start() {
        guard let binary = Bundle.main.executableURL?.path else { return }
        let arguments = [binary, SessionHelperMain.flag, "--socket", socketPath, "--build", SessionHelper.buildID,
                         "--mac-listen", String(port), "--mac-name", computerName]
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "EnvironmentVariables": [MacLink.secretVariable: MacPairings.workerSecret],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "AbandonProcessGroup": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0) else { return }
        let unchanged = FileManager.default.contents(atPath: plistPath) == data
        if unchanged, launchctl(["print", "\(domain)/\(label)"]) { return }
        launchctl(["bootout", "\(domain)/\(label)"])
        // It holds the secret: readable by you only.
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: plistPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return NSLog("agterm: couldn't write %@", plistPath)
        }
        if !launchctl(["bootstrap", domain, plistPath]) { NSLog("agterm: couldn't start the worker for other Macs") }
    }

    /// Stops it and the tasks it is running.
    private static func stop() {
        launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// Unpairs every Mac that has the old code.
    static func newCode() {
        queue.async { MacPairings.newWorkerSecret() }
        update()
    }

    static var isRunning: Bool { launchctl(["print", "\(domain)/\(label)"]) }

    private static var label: String { (Bundle.main.bundleIdentifier ?? "agterm-dev") + ".mac-worker" }
    private static var domain: String { "gui/\(getuid())" }
    private static var stateDir: String { WorkspaceStore.fileURL.deletingLastPathComponent().path }
    private static var plistPath: String { stateDir + "/mac-worker.plist" }
    private static var socketPath: String { SessionPaths.socket(stateDir: stateDir + "/mac-worker") }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
