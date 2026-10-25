import AgTermCore
import Foundation

/// Runs ⌘K's model through the agent CLI you're signed in to (no API keys), and finds which
/// CLIs are installed using your login shell's PATH, since apps opened from the Dock don't get it.
final class QuickCommandRunner {
    static let shared = QuickCommandRunner()
    static let modelKey = "quickCommandModel"
    static let timeout: TimeInterval = 30

    enum Failure: Error {
        case noModel, timedOut, emptyReply
        case failed(String)

        var message: String {
            switch self {
            case .noModel: "Install Claude Code, Codex or Grok to use ⌘K."
            case .timedOut: "The model took longer than \(Int(QuickCommandRunner.timeout)) seconds."
            case .emptyReply: "The model didn't reply with a command."
            case let .failed(detail): detail
            }
        }
    }

    /// One request. Cancelling before it starts stops it from starting; after, it's killed.
    final class Run {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if let running { QuickCommandRunner.stop(running) }
        }

        /// Starts `process` unless this run was already cancelled.
        fileprivate func start(_ process: Process) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            try process.run()
            self.process = process
            return true
        }
    }

    private let lock = NSLock()
    private var resolvedPath: String?

    /// Your preference from Settings; nil means Automatic.
    var preferred: QuickModel? {
        UserDefaults.standard.string(forKey: Self.modelKey).flatMap(QuickModel.init(rawValue:))
    }

    /// Resolves the PATH in the background so the first ⌘K doesn't wait on your shell's startup files.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = self.path() }
    }

    /// Your login shell's PATH plus the usual install folders (waits for it the first time).
    var searchPath: String { path() }

    /// True once the PATH is known, so asking what's installed won't wait on your shell.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolvedPath != nil
    }

    /// The model ⌘K would use now, or nil if no CLI is installed.
    func currentModel() -> QuickModel? {
        QuickCommand.pick(preferred: preferred, installed: installed())
    }

    func installed() -> Set<QuickModel> {
        Set(QuickModel.allCases.filter { executable($0.cli) != nil })
    }

    func executable(_ name: String) -> String? {
        let skip = AgentIntegration.binDir.path
        for dir in path().split(separator: ":").map(String.init) where dir != skip && !dir.isEmpty {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Asks the model; `completion` runs on the main queue unless the run was cancelled.
    func generate(request: String, cwd: String, shell: String, screen: String,
                  completion: @escaping (QuickModel?, Result<String, Failure>) -> Void) -> Run {
        let run = Run()
        let message = QuickCommand.message(request: request, cwd: cwd, shell: shell, screen: screen)
        // Each request on its own thread, so one stuck CLI can't hold up the next ⌘K.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let model = self.currentModel(), let cli = self.executable(model.cli) else {
                return DispatchQueue.main.async { completion(nil, .failure(.noModel)) }
            }
            let session = UUID().uuidString.lowercased()
            let process = self.process(cli, QuickCommand.arguments(model, message: message,
                                                                    codex: model == .codex ? Self.codexModel() : .fallback,
                                                                    sessionID: session))
            let result = Self.reply(Self.execute(process, timeout: Self.timeout, start: run.start))
            if !run.isCancelled { DispatchQueue.main.async { completion(model, result) } }
            if model == .grok {
                // Grok saves every run; keep ⌘K out of its history.
                _ = Self.execute(self.process(cli, ["sessions", "delete", session]), timeout: 10)
            }
        }
        return run
    }

    private func process(_ cli: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.environment = environment()
        // An empty folder, so no project instructions or files are read.
        process.currentDirectoryURL = Self.workDir()
        return process
    }

    private static func reply(_ outcome: Outcome) -> Result<String, Failure> {
        switch outcome {
        case .cancelled: return .failure(.failed("Cancelled."))
        case let .couldNotStart(error): return .failure(.failed("Couldn't start the model: \(error.localizedDescription)"))
        case .timedOut: return .failure(.timedOut)
        case let .exited(status, out, err):
            guard status == 0 else {
                let detail = String(decoding: err, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
                return .failure(.failed(detail.isEmpty ? "The model exited with status \(status)." : detail))
            }
            guard let command = QuickCommand.clean(String(decoding: out, as: UTF8.self)) else { return .failure(.emptyReply) }
            return .success(command)
        }
    }

    // MARK: Running a process with a deadline

    enum Outcome {
        case cancelled, timedOut
        case couldNotStart(Error)
        case exited(Int32, Data, Data)
    }

    /// Runs `process` to completion or `timeout`, whichever comes first. Output is read as it
    /// arrives, so a full pipe can't stall the child, and a leftover grandchild holding the pipe
    /// open can't stall us.
    static func execute(_ process: Process, timeout: TimeInterval,
                        start: (Process) throws -> Bool = { try $0.run(); return true }) -> Outcome {
        let out = Collector(), err = Collector()
        process.standardOutput = out.pipe
        process.standardError = err.pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            guard try start(process) else { return .cancelled }
        } catch {
            return .couldNotStart(error)
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            stop(process)
            _ = exited.wait(timeout: .now() + 3)
            return .timedOut
        }
        return .exited(process.terminationStatus, out.finish(), err.finish())
    }

    /// SIGTERM, then SIGKILL two seconds later if it's still there. kill() rather than
    /// terminate(), which throws if the process has already gone.
    static func stop(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private final class Collector {
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private let eof = DispatchSemaphore(value: 0)

        init() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self.eof.signal()
                } else {
                    self.lock.lock()
                    self.data.append(chunk)
                    self.lock.unlock()
                }
            }
        }

        /// Everything read so far, waiting briefly for the rest.
        func finish() -> Data {
            _ = eof.wait(timeout: .now() + 1)
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path()
        for key in env.keys where key.hasPrefix("AGTERM_") || key == "CLAUDECODE" { env[key] = nil }
        return env
    }

    private static func workDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-quick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func codexModel() -> CodexFastModel {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        guard let data = FileManager.default.contents(atPath: home + "/models_cache.json") else { return .fallback }
        return CodexFastModel.from(modelsCache: data)
    }

    // MARK: PATH

    /// Your interactive login shell's PATH (where installers like Claude Code's put ~/.local/bin),
    /// plus the usual install folders. Worked out once.
    private func path() -> String {
        lock.lock()
        if let resolvedPath {
            lock.unlock()
            return resolvedPath
        }
        lock.unlock()
        let home = NSHomeDirectory()
        let common = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local",
                      "\(home)/.bun/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var dirs = (Self.loginShellPath() ?? "").split(separator: ":").map(String.init)
        for dir in common where !dirs.contains(dir) { dirs.append(dir) }
        let joined = dirs.joined(separator: ":")
        lock.lock()
        resolvedPath = joined
        lock.unlock()
        return joined
    }

    private static func loginShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcInfo.loginShell())
        // Markers, since startup files may print their own output.
        process.arguments = ["-i", "-l", "-c", #"printf '__AGTERM_PATH__%s__END__' "$PATH""#]
        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = nil
        process.environment = env
        guard case let .exited(_, data, _) = execute(process, timeout: 5) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "__AGTERM_PATH__"), let end = text.range(of: "__END__", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
