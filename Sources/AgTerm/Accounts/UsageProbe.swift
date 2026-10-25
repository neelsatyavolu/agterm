import AgTermCore
import Foundation

/// Reads a login's usage by asking its own CLI, which already holds the token: Claude Code's
/// `get_usage` control request (about 0.6 s) and Codex's app-server `account/rateLimits/read`
/// (about 1 s). Nothing is read from the Keychain, and no model is called. Blocking; run off
/// the main thread.
enum UsageProbe {
    static let timeout: TimeInterval = 20

    struct Result {
        let reading: UsageReading?
        /// Signed in at all (an account with no usage windows can still be signed in).
        let signedIn: Bool
        let error: String?
    }

    static func read(_ provider: AccountProvider, home: URL?) -> Result {
        guard let cli = QuickCommandRunner.shared.executable(provider.rawValue) else {
            return Result(reading: nil, signedIn: false, error: "\(provider.title) isn't installed")
        }
        switch provider {
        case .claude: return claude(cli: cli, home: home)
        case .codex: return codex(cli: cli, home: home)
        }
    }

    private static func claude(cli: String, home: URL?) -> Result {
        let args = ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--no-session-persistence", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--tools", "",
                    "--disable-slash-commands", "--settings", #"{"disableAllHooks":true}"#, "--setting-sources", "user"]
        let requests = [
            #"{"type":"control_request","request_id":"init","request":{"subtype":"initialize","hooks":{},"sdkMcpServers":[]}}"#,
            #"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#,
        ]
        var account: [String: Any]?
        var usage: [String: Any]?
        let finished = LineProcess.run(cli, args, env: environment(.claude, home: home), input: requests) { line, _ in
            guard let record = json(line), record["type"] as? String == "control_response",
                  let response = record["response"] as? [String: Any] else { return false }
            let body = response["response"] as? [String: Any]
            switch response["request_id"] as? String {
            case "init": account = body?["account"] as? [String: Any]
            case "usage": usage = body ?? [:]
            default: break
            }
            return usage != nil
        }
        guard finished else { return Result(reading: nil, signedIn: false, error: "Claude Code didn't answer") }
        // An API key or other provider isn't a subscription login; there's nothing to switch.
        let signedIn = account?["subscriptionType"] != nil && account?["apiKeySource"] == nil
        guard signedIn else { return Result(reading: nil, signedIn: false, error: "Not signed in to a Claude subscription") }
        let reading = usage.flatMap { UsageParser.claude(usage: $0, account: account, now: Date()) }
            ?? UsageReading(windows: [], plan: account?["subscriptionType"] as? String, email: account?["email"] as? String, checkedAt: Date())
        return Result(reading: reading, signedIn: true, error: usage?["rate_limits_available"] as? Bool == false ? "Usage isn't available right now" : nil)
    }

    private static func codex(cli: String, home: URL?) -> Result {
        var limits: [String: Any]?
        var account: [String: Any]?
        var failure: String?
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"agterm","version":"1"},"capabilities":{"experimentalApi":true}}}"#
        let finished = LineProcess.run(cli, ["app-server"], env: environment(.codex, home: home), input: [initialize]) { line, send in
            guard let record = json(line), let id = record["id"] as? Int else { return false }
            switch id {
            case 1:
                send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
                send(#"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{"refreshToken":false}}"#)
                send(#"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}"#)
            case 2:
                account = (record["result"] as? [String: Any])?["account"] as? [String: Any] ?? [:]
            case 3:
                limits = record["result"] as? [String: Any]
                if limits == nil { failure = ((record["error"] as? [String: Any])?["message"] as? String) ?? "No usage" }
            default: break
            }
            return account != nil && (limits != nil || failure != nil)
        }
        guard finished else { return Result(reading: nil, signedIn: false, error: "Codex didn't answer") }
        let signedIn = account?["type"] as? String == "chatgpt" || account?["email"] != nil
        guard signedIn else { return Result(reading: nil, signedIn: false, error: "Not signed in to ChatGPT") }
        let plan = account?["planType"] as? String, email = account?["email"] as? String
        let reading = limits.map { UsageParser.codex(rateLimits: $0, plan: plan, email: email, now: Date()) }
            ?? UsageReading(windows: [], plan: plan, email: email, checkedAt: Date())
        return Result(reading: reading, signedIn: true, error: failure)
    }

    /// Your environment with the login's folder set and any API key removed, so the CLI reports
    /// on that subscription login and nothing else.
    static func environment(_ provider: AccountProvider, home: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = QuickCommandRunner.shared.searchPath
        for key in env.keys where key.hasPrefix("AGTERM_") { env[key] = nil }
        for key in provider == .claude ? ClaudeAuthEnv.keys : ClaudeAuthEnv.codexKeys { env[key] = nil }
        env[provider.homeVariable] = home?.path
        return env
    }

    private static func json(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// Runs a CLI that talks in JSON lines: writes `input`, hands each output line to `handle`
/// (which may write more), and stops when `handle` says it's done or the deadline passes.
enum LineProcess {
    static func run(_ cli: String, _ args: [String], env: [String: String], input: [String],
                    timeout: TimeInterval = UsageProbe.timeout,
                    handle: @escaping (String, (String) -> Void) -> Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data(), finished = false
        let send: (String) -> Void = { line in try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        stdout.fileHandleForReading.readabilityHandler = { handle_ in
            let chunk = handle_.availableData
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            if chunk.isEmpty {
                handle_.readabilityHandler = nil
                done.signal()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if handle(line, send) {
                    finished = true
                    done.signal()
                    return
                }
            }
        }
        do { try process.run() } catch { return false }
        input.forEach(send)
        _ = done.wait(timeout: .now() + timeout)
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        QuickCommandRunner.stop(process)
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}
