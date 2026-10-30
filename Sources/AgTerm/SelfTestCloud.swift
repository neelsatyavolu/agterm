#if DEBUG
import AgTermCore
import AgTermSessionKit
import AppKit

extension SelfTest {
    /// Cloud tabs: `AGTERM_CLOUD_CHECK=1 AGTERM_SELFTEST=<dir>`. Runs a sessions helper and its
    /// gateway in-process on loopback (as `agterm-sessions --listen` does on a cloud machine), or
    /// uses the machine in `AGTERM_CLOUD`/`AGTERM_CLOUD_TOKEN` (a Linux container, say). Opens a
    /// tab through the gateway, types into it, resizes it, then attaches a second tab to the same
    /// shell, which must replay its screen. Writes `cloud-tab.png`.
    static func cloudCheck(_ controller: MainWindowController, outDir: String) {
        var passed = true
        func report(_ name: String, _ ok: Bool) {
            print("cloud: \(name):", ok)
            passed = passed && ok
        }
        let local = CloudHost.configured == nil ? startCloud() : nil
        guard let window = controller.window, let cloud = CloudHost.configured ?? local?.cloud else {
            print("cloud: couldn't start the helper and gateway")
            exit(1)
        }
        func finish() {
            local?.gateway.stop()
            local?.server.stop()
            exit(passed ? 0 : 1)
        }
        window.setContentSize(NSSize(width: 900, height: 420))
        controller.showWindow(nil)
        let wrong = CloudHost(url: cloud.url, machine: cloud.machine, token: String(repeating: "x", count: 32))
        report("wrong token refused", (try? wrong.spawn(SpawnRequest(executable: "/bin/sh", argv: ["-sh"], env: [], cwd: "/",
                                                                     cols: 80, rows: 24))) == nil)
        controller.openCloudTab(cloud)
        guard let first = controller.sessions.last, let id = first.view.link.sessionID else {
            print("cloud: no cloud tab")
            exit(1)
        }
        report("no local pid or pty", first.view.link.shellPid == 0 && first.view.link.ptyFd == -1)
        after(1) { first.view.send(txt: "echo CLOUD-$((6*7))\r") }
        waitFor({ screenLine(first, containing: "CLOUD-42") != nil }) { typed in
            report("typed over the network", typed)
            window.setContentSize(NSSize(width: 760, height: 360))
            window.layoutIfNeeded()
            let terminal = first.view.getTerminal()
            let size = "\(terminal.rows) \(terminal.cols)"
            first.view.send(txt: "stty size\r")
            waitFor({ screenLine(first, containing: size).map { !$0.contains("stty") } == true }) { resized in
                report("resize reaches the shell (\(size))", resized)
                snapshot(window, "\(outDir)/cloud-tab.png")
                first.view.send(txt: "sleep 3\r")
                waitFor({ first.pollProcess(); return first.foregroundName == "sleep" && first.isRunningProgram }) { seen in
                    report("foreground program seen through the helper", seen)
                    waitFor({ first.pollProcess(); return !first.isRunningProgram }) { _ in
                        reattach(controller, cloud: cloud, first: first, id: id, report: report, finish: finish)
                    }
                }
            }
        }
    }

    /// A second tab attached to `first`'s shell replays its screen and supersedes it; closing
    /// that tab ends the cloud shell.
    private static func reattach(_ controller: MainWindowController, cloud: CloudHost, first: TerminalSession, id: String,
                                 report: @escaping (String, Bool) -> Void, finish: @escaping () -> Void) {
        controller.openCloudTab(cloud, attaching: id)
        let second = controller.sessions.last!
        waitFor({ screenLine(second, containing: "CLOUD-42") != nil }) { replayed in
            report("second tab replays the screen", replayed)
            report("listed as attached", cloud.list()?.first { $0.id == id }?.attached == true)
            waitFor({ first.signals.exited }) { superseded in
                report("first tab superseded", superseded)
                second.terminate()
                waitFor({ cloud.list()?.isEmpty == true }) { ended in
                    report("closing ends the cloud shell", ended)
                    finish()
                }
            }
        }
    }

    private static func startCloud() -> (server: SessionServer, gateway: SessionGateway, cloud: CloudHost)? {
        var template = Array("/tmp/agcl.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { return nil }
        let socket = String(cString: made) + "/s.sock"
        let token = UUID().uuidString + UUID().uuidString
        let server = SessionServer(socketPath: socket, build: SessionHelper.buildID)
        server.idleExitAfter = nil
        let gateway = SessionGateway(socketPath: socket, host: "127.0.0.1", port: 0, token: token)
        guard (try? server.start()) != nil, (try? gateway.start()) != nil else { return nil }
        return (server, gateway, CloudHost(url: URL(string: "ws://127.0.0.1:\(gateway.port)/")!, token: token))
    }

    /// Polls `condition` on the main queue every 0.1 s for up to `timeout`, then calls `done`.
    static func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 8, _ done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { return done(true) }
            if Date() > deadline { return done(false) }
            after(0.1, poll)
        }
        poll()
    }
}
#endif
