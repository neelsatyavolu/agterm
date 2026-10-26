import AgTermCore
import Foundation

/// Reads a login's usage by asking its own CLI, which already holds the token: Claude Code's
/// `get_usage` control request (about 0.6 s) and Codex's app-server `account/rateLimits/read`
/// (about 1 s). Grok's CLI has no such request, so its usage comes from grok.com's billing
/// reply with the login's own token. Nothing is read from the Keychain, and no model is
/// called. Blocking; run off the main thread.
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
        case .grok: return grok(cli: cli, home: home)
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

    private static func grok(cli: String, home: URL?) -> Result {
        let folder = home ?? AccountStore.nativeGrokHome
        guard var login = grokLogin(folder) else { return Result(reading: nil, signedIn: false, error: "Not signed in to Grok") }
        // Access tokens last 6 hours and only the CLI renews them.
        var refreshed = false
        if let expires = login.expiresAt, expires < Date().addingTimeInterval(60) {
            refreshGrok(cli: cli, home: home)
            refreshed = true
            login = grokLogin(folder) ?? login
        }
        var reply = grokBilling(login.token)
        if [401, 403].contains(reply.status), !refreshed {
            refreshGrok(cli: cli, home: home)
            if let fresh = grokLogin(folder), fresh.token != login.token {
                login = fresh
                reply = grokBilling(login.token)
            }
        }
        let plan = grokPlan(folder)
        switch reply.status {
        case 200..<300:
            guard let snapshot = GrokBilling.parse(reply.data, now: Date()) else {
                return Result(reading: UsageReading(windows: [], plan: plan, email: login.email, checkedAt: Date()), signedIn: true,
                              error: "Grok didn't report usage")
            }
            return Result(reading: GrokBilling.reading(snapshot, plan: plan, email: login.email, now: Date()), signedIn: true, error: nil)
        case 401, 403:
            return Result(reading: nil, signedIn: false, error: "Grok's sign-in expired; run grok on this account to renew it")
        case 0:
            return Result(reading: nil, signedIn: true, error: "grok.com couldn't be reached")
        default:
            return Result(reading: UsageReading(windows: [], plan: plan, email: login.email, checkedAt: Date()), signedIn: true,
                          error: "Usage isn't available right now")
        }
    }

    private static func grokLogin(_ folder: URL) -> GrokAuth.Login? {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent("auth.json").path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return GrokAuth.login(json)
    }

    /// `grok models` signs in like a session would, renewing an expired token, and calls no model.
    private static func refreshGrok(cli: String, home: URL?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["models"] + (home.map { ["--leader-socket", AccountStore.grokLeaderSocket($0)] } ?? [])
        process.environment = environment(.grok, home: home)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        _ = QuickCommandRunner.execute(process, timeout: timeout)
    }

    /// One billing request; status 0 when it didn't get through. A 429 or a gateway error is
    /// tried once more.
    private static func grokBilling(_ token: String) -> (status: Int, data: Data) {
        var request = URLRequest(url: GrokBilling.url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = GrokBilling.requestBody
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("agterm", forHTTPHeaderField: "User-Agent")
        var reply: (status: Int, data: Data) = (0, Data())
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 2) }
            // Each attempt has its own answer, so a late one can't land in the next.
            let answer = Answer()
            let done = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                answer.set(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
                done.signal()
            }
            task.resume()
            if done.wait(timeout: .now() + 20) == .timedOut { task.cancel() }
            reply = answer.get() ?? (0, Data())
            guard [0, 429, 502, 503, 504].contains(reply.status) else { break }
        }
        return reply
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Int, Data)?
        func set(_ value: (Int, Data)) { lock.withLock { self.value = value } }
        func get() -> (status: Int, data: Data)? { lock.withLock { value } }
    }

    /// The plan the CLI last logged for this login, from the end of its unified.jsonl.
    private static func grokPlan(_ folder: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("logs/unified.jsonl")) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return GrokBilling.plan(logTail: String(decoding: data, as: UTF8.self))
    }

    /// Your environment with the login's folder set and any API key removed, so the CLI reports
    /// on that subscription login and nothing else.
    static func environment(_ provider: AccountProvider, home: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = QuickCommandRunner.shared.searchPath
        for key in env.keys where key.hasPrefix("AGTERM_") { env[key] = nil }
        for key in provider.authKeys { env[key] = nil }
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
