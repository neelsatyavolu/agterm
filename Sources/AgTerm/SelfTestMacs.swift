#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Settings → Macs end to end on one Mac: `AGTERM_MACS_CHECK=1 AGTERM_SELFTEST=<dir>`. Turns on
    /// the worker (a launchd job, on port 47998), pairs this Mac with itself over loopback, and runs
    /// `agterm-remote` from agterm's bin folder in a scratch repo: output, exit status, git-ignored
    /// files left behind, `--back`, and a removed Mac. Turns the worker off and puts the paired
    /// Macs back as they were. Snapshots the pane with the worker on (`macs-settings.png`).
    static func macsCheck(outDir: String) {
        let defaults = UserDefaults.standard
        let savedPairings = MacPairings.all
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: macs: \(name):", ok ? "ok" : "FAIL \(detail)")
            if !ok { failed = true }
        }
        defaults.set(47998, forKey: MacWorker.portKey)
        MacWorker.setEnabled(true) {
            report("worker job running", MacWorker.isRunning)
            var pairing = MacWorker.pairing
            pairing.host = "127.0.0.1"
            pairing.name = "agterm-selftest"
            savedPairings.forEach { MacPairings.remove(named: $0.name) }
            MacPairings.add(pairing)
            report("names for agents", MacPairings.names == ["agterm-selftest"], "\(MacPairings.names)")
            var answer: String?
            for _ in 0..<20 {
                answer = MacHost(pairing).check()
                if answer == nil { break }
                usleep(250_000)
            }
            report("paired Mac answers", answer == nil, answer ?? "")

            let repo = outDir + "/macs-repo"
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.createDirectory(atPath: repo + "/node_modules", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: repo + "/a.txt", contents: Data("hello\n".utf8))
            FileManager.default.createFile(atPath: repo + "/.gitignore", contents: Data("node_modules/\n.env\n".utf8))
            FileManager.default.createFile(atPath: repo + "/.env", contents: Data("KEY=1\n".utf8))
            FileManager.default.createFile(atPath: repo + "/node_modules/x", contents: Data())
            _ = shell(["/usr/bin/git", "init", "-q"], in: repo)

            let wrapper = AgentIntegration.binDir.appendingPathComponent(AgentIntegration.remoteCommand).path
            let run = shell([wrapper, "run", "--back", "--", "cat a.txt; ls -A; echo made > out.txt; exit 7"], in: repo)
            report("output comes back", run.stdout.contains("hello"), run.stdout + run.stderr)
            report("exit status comes back", run.status == 7, "\(run.status)")
            report("git-ignored files stay here", !run.stdout.contains(".env") && !run.stdout.contains("node_modules"), run.stdout)
            report("--back copies results", FileManager.default.fileExists(atPath: repo + "/out.txt"))
            let list = shell([wrapper, "list"], in: repo)
            report("list says ready", list.stdout.contains("agterm-selftest (default)") && list.stdout.contains("ready"), list.stdout + list.stderr)

            DispatchQueue.main.async {
                SettingsWindowController.shared.show(pane: "Macs")
                after(1) {
                    snapshotSettings("\(outDir)/macs-settings.png")
                    DispatchQueue.global().async {
                        MacPairings.remove(named: "agterm-selftest")
                        let gone = shell([wrapper, "run", "--", "true"], in: repo)
                        report("no Mac paired is explained", gone.status == 255 && gone.stderr.contains("no Mac is paired"), gone.stderr)
                        MacWorker.setEnabled(false) {
                            // It gives running commands a few seconds to stop first.
                            var stopped = false
                            for _ in 0..<40 where !stopped {
                                stopped = !MacWorker.isRunning
                                if !stopped { usleep(250_000) }
                            }
                            report("worker stops", stopped)
                            savedPairings.forEach(MacPairings.add)
                            defaults.removeObject(forKey: MacWorker.portKey)
                            print("selftest: macs:", failed ? "FAILED" : "all ok")
                            exit(failed ? 1 : 0)
                        }
                    }
                }
            }
        }
    }

    private static func shell(_ argv: [String], in dir: String) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return (-1, "", "couldn't start \(argv[0])") }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }
}
#endif
