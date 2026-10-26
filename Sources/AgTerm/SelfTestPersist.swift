#if DEBUG
import AgTermCore
import AgTermSessionKit
import AppKit

extension SelfTest {
    /// Tabs outlive a quit: `AGTERM_PERSIST_CHECK=1 AGTERM_SELFTEST=<dir> AGTERM_STATE_DIR=/tmp/agt-persist`
    /// (an empty state folder; a short one keeps the helper's socket path short). Opens two tabs,
    /// quits the way ⌘Q does (save, detach every tab, drop the window), then, while agterm is
    /// "closed", the helper gains a session nobody saved and one tab's shell is killed. A new
    /// window must reattach the live shells, adopt the stray one, reopen the dead one from its
    /// saved history, and Quit and End Sessions must then leave no shells.
    static func persistCheck(_ controller: MainWindowController) {
        var passed = true
        func report(_ name: String, _ ok: Bool) {
            print("persist: \(name):", ok)
            passed = passed && ok
        }
        after(1) {
            controller.newTab()
            controller.sessions.last?.view.send(txt: "echo PERSIST-$$\r")
            controller.newTab()
            controller.sessions.last?.view.send(txt: "echo SAVED-MARK\r")
        }
        after(3) {
            guard let helper = SessionHelper.shared(), controller.sessions.allSatisfy(\.isKeptByHelper) else {
                print("persist: tabs aren't in the helper")
                exit(1)
            }
            let kept = controller.sessions[controller.sessions.count - 2], killed = controller.sessions.last!
            let before = controller.sessions.map { $0.view.link.sessionID }
            let selected = controller.sessions.count - 1
            let keptID = kept.view.link.sessionID, keptPid = kept.view.link.shellPid, keptTab = kept.tabID
            let killedID = killed.view.link.sessionID, killedPid = killed.view.link.shellPid

            // ⌘Q, minus the process exit.
            controller.quit(endingSessions: false)
            controller.window?.delegate = nil
            controller.window?.orderOut(nil)

            // Started outside any saved tab, like a shell from a run that crashed before saving.
            let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            let stray = try? helper.spawn(SpawnRequest(executable: "/bin/zsh", argv: ["-zsh"], env: env, cwd: "/tmp", cols: 80, rows: 24))
            let strayID = stray?.sessionID
            stray?.detach()
            kill(killedPid, SIGKILL)

            after(1.5) {
                let next = MainWindowController()
                after(2) {
                    let ids = next.sessions.map { $0.view.link.sessionID }
                    let reattached = next.sessions.first { $0.view.link.sessionID == keptID }
                    let samePid = reattached.map { $0.view.link.shellPid == keptPid && $0.tabID == keptTab } ?? false
                    report("same shell after reattach", samePid && reattached.map { screenLine($0, containing: "PERSIST-\(keptPid)") != nil } == true)

                    // Saved tabs in their order, the dead one replaced, the stray one last, selection kept.
                    let ordered = ids.count == before.count + 1 && Array(ids.prefix(before.count - 1)) == Array(before.prefix(before.count - 1))
                    let selection = next.sessions.indices.contains(selected) && next.selectedTabIDForTest == next.sessions[selected].tabID
                    if !ordered || !selection { print("persist: tabs after relaunch:", ids, "selected index kept:", selection) }
                    let adopted = strayID != nil && ids.last == strayID && ordered && selection

                    let restored = next.sessions.indices.contains(before.count - 1) ? next.sessions[before.count - 1] : nil
                    let fromSave = restored.map {
                        $0.view.link.sessionID != killedID && screenLine($0, containing: "SAVED-MARK") != nil && screenLine($0, containing: "restored") != nil
                    } ?? false

                    reattached?.view.send(txt: "echo AF''TER\r")
                    after(1) {
                        report("typing works after reattach", reattached.map { screenLine($0, containing: "AFTER") != nil } ?? false)
                        report("orphan adopted", adopted)
                        report("exited session restored from save", fromSave)
                        let pids = next.sessions.map { $0.view.link.shellPid }
                        next.quit(endingSessions: true)
                        after(3) {
                            let left = helper.list()
                            let alive = pids.filter { kill($0, 0) == 0 }
                            if !left.isEmpty || !alive.isEmpty { print("persist: left behind:", left.map(\.id), "pids:", alive) }
                            report("quit-and-end leaves no shells", left.isEmpty && alive.isEmpty)
                            exit(passed ? 0 : 2)
                        }
                    }
                }
            }
        }
    }

    /// Ends every shell the helper for this state folder keeps, waiting up to 3 s for them to go,
    /// so a self-test that exits leaves nothing for the next run to adopt as tabs. Quitting no
    /// longer ends shells, so self-tests call this on exit.
    static func endHelperSessions() {
        guard let (connection, _) = try? HelperHandshake.connect(socket: SessionHelper.socketPath, build: SessionHelper.buildID,
                                                                 timeout: 0.5) else { return }
        defer { connection.close() }
        let deadline = Date().addingTimeInterval(3)
        var signalled = Set<String>()
        while Date() < deadline, let infos = sessions(on: connection), !infos.isEmpty {
            for info in infos where !signalled.contains(info.id) {
                try? connection.send(.kill(id: info.id, signal: SIGHUP))
                signalled.insert(info.id)
            }
            usleep(50_000)
        }
    }

    /// `list`, skipping any error reply left by a kill that raced its session's exit.
    private static func sessions(on connection: WireConnection) -> [SessionInfo]? {
        guard (try? connection.send(.list)) != nil else { return nil }
        while let message = try? connection.receive(timeout: 1) {
            if case .sessions(let infos) = message { return infos }
        }
        return nil
    }
}
#endif
