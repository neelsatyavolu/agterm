import XCTest
@testable import AgTermCore

final class AccountUsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testClaudeUsageFromControlResponse() throws {
        let usage: [String: Any] = [
            "rate_limits_available": true,
            "rate_limits": [
                "five_hour": ["utilization": 8, "resets_at": "2026-10-25T21:40:00.264447+00:00"],
                "seven_day": ["utilization": 20, "resets_at": "2026-10-31T08:00:00+00:00"],
                "iguana_necktie": ["utilization": 0],
                "extra_usage": ["utilization": NSNull()],
            ],
        ]
        let reading = try XCTUnwrap(UsageParser.claude(usage: usage, account: ["subscriptionType": "Claude Max", "email": "a@b.c"], now: now))
        XCTAssertEqual(reading.windows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(reading.remainingPercent, 80)
        XCTAssertEqual(reading.plan, "Claude Max")
        XCTAssertNotNil(reading.windows[0].resetsAt)
        XCTAssertNil(UsageParser.claude(usage: ["rate_limits_available": false], account: nil, now: now))
    }

    func testCodexUsageFromAppServerAndRollout() {
        let appServer: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 15, "windowDurationMins": 10080, "resetsAt": 1_793_513_829],
            "secondary": NSNull(), "credits": ["hasCredits": false], "planType": "prolite",
        ]]
        let reading = UsageParser.codex(rateLimits: appServer, now: now)
        XCTAssertEqual(reading.windows.map(\.name), ["Weekly"])
        XCTAssertEqual(reading.remainingPercent, 85)
        XCTAssertEqual(reading.plan, "Pro 5x")
        XCTAssertEqual(UsageParser.codexPlanName("pro"), "Pro 20x")
        XCTAssertEqual(UsageParser.codexPlanName("pro500"), "Pro500")
        let rollout: [String: Any] = ["primary": ["used_percent": 100.0, "window_minutes": 300, "resets_at": 1_790_003_600],
                                      "credits": ["has_credits": false]]
        let out = UsageParser.codex(rateLimits: rollout, now: now)
        XCTAssertEqual(out.windows.first?.name, "5-hour")
        XCTAssertEqual(out.exhaustedUntil(now), Date(timeIntervalSince1970: 1_790_003_600))
    }

    func testCreditsMeanNotExhausted() {
        let reading = UsageReading(windows: [UsageWindow(name: "Weekly", usedPercent: 100, resetsAt: now.addingTimeInterval(60))],
                                   hasCredits: true, checkedAt: now)
        XCTAssertNil(reading.exhaustedUntil(now))
    }

    func testExhaustionEndsAtReset() {
        let reading = UsageReading(windows: [UsageWindow(name: "5-hour", usedPercent: 100, resetsAt: now.addingTimeInterval(-1))], checkedAt: now)
        XCTAssertNil(reading.exhaustedUntil(now))
    }
}

final class LimitDetectorTests: XCTestCase {
    func testClaudeLimitRecord() {
        let line = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"isSidechain":false,"message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your weekly limit · resets 1am (America/Los_Angeles)"}]}}"#
        XCTAssertEqual(LimitDetector.claude(line: line)?.message, "You've hit your weekly limit · resets 1am (America/Los_Angeles)")
        XCTAssertNil(LimitDetector.claude(line: line.replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)))
        XCTAssertNil(LimitDetector.claude(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"rate_limit is a word"}]}}"#))
    }

    func testCodexLimitEvents() {
        let error = #"{"type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Try again in 2 days."}}"#
        XCTAssertNotNil(LimitDetector.codex(line: error))
        let reached = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"rate_limit_reached_type":"primary","credits":{"has_credits":false}}}}"#
        XCTAssertNotNil(LimitDetector.codex(line: reached))
        let withCredits = reached.replacingOccurrences(of: #""has_credits":false"#, with: #""has_credits":true"#)
        XCTAssertNil(LimitDetector.codex(line: withCredits))
        let normal = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"rate_limit_reached_type":null}}}"#
        XCTAssertNil(LimitDetector.codex(line: normal))
    }
}

final class AccountPickerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func reading(_ used: Double) -> UsageReading {
        UsageReading(windows: [UsageWindow(name: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(3600))], checkedAt: now)
    }

    func testPicksMostRemainingAndSkipsExhausted() {
        let candidates = [
            AccountPicker.Candidate(id: "native", reading: reading(100)),
            AccountPicker.Candidate(id: "a", reading: reading(70)),
            AccountPicker.Candidate(id: "b", reading: reading(10)),
            AccountPicker.Candidate(id: "c", enabled: false, reading: reading(0)),
        ]
        XCTAssertEqual(AccountPicker.next(candidates, excluding: [], now: now), "b")
        XCTAssertEqual(AccountPicker.next(candidates, excluding: ["b"], now: now), "a")
    }

    func testUnknownUsageIsALastResortAndBlocksHold() {
        let candidates = [
            AccountPicker.Candidate(id: "native", reading: nil),
            AccountPicker.Candidate(id: "a", reading: nil, blockedUntil: now.addingTimeInterval(60)),
        ]
        XCTAssertEqual(AccountPicker.next(candidates, excluding: [], now: now), "native")
        XCTAssertNil(AccountPicker.next(candidates, excluding: ["native"], now: now))
        XCTAssertEqual(AccountPicker.next(candidates, excluding: ["native"], now: now.addingTimeInterval(61)), "a")
    }

    func testNewSessionsStayOnTheChosenLoginWhileItHasUsage() {
        let candidates = [
            AccountPicker.Candidate(id: "native", reading: reading(0)),
            AccountPicker.Candidate(id: "a", reading: reading(60)),
        ]
        XCTAssertEqual(AccountPicker.forNewSessions(candidates, home: "a", autoSwitch: true, now: now), "a")
        XCTAssertEqual(AccountPicker.forNewSessions(candidates, home: "native", autoSwitch: true, now: now), "native")
    }

    func testNewSessionsLeaveAUsedUpChosenLoginOnlyWhenSwitching() {
        let candidates = [
            AccountPicker.Candidate(id: "native", reading: reading(40)),
            AccountPicker.Candidate(id: "a", reading: reading(100)),
            AccountPicker.Candidate(id: "b", reading: reading(10)),
        ]
        XCTAssertEqual(AccountPicker.forNewSessions(candidates, home: "a", autoSwitch: true, now: now), "b")
        XCTAssertEqual(AccountPicker.forNewSessions(candidates, home: "a", autoSwitch: false, now: now), "a")
        let allOut = candidates.map { AccountPicker.Candidate(id: $0.id, reading: reading(100)) }
        XCTAssertNil(AccountPicker.forNewSessions(allOut, home: "a", autoSwitch: true, now: now))
    }
}

final class CodexResumeTests: XCTestCase {
    func testKeepsOptionsDropsPrompt() {
        XCTAssertEqual(AgentResume.codexCommandLine(userArgs: ["-m", "gpt-6-sol", "--search", "fix the login bug"], sessionID: "abc-123-def"),
                       "command codex resume abc-123-def -m gpt-6-sol --search")
        XCTAssertEqual(AgentResume.codexCommandLine(userArgs: ["resume", "--last", "-c", "model_reasoning_effort=high"], sessionID: "abc-123-def"),
                       "command codex resume abc-123-def -c model_reasoning_effort\\=high")
        XCTAssertNil(AgentResume.codexCommandLine(userArgs: ["exec", "do it"], sessionID: "abc-123-def"))
    }

    func testSessionIDFromHeader() {
        XCTAssertEqual(AgentResume.codexSessionID(rolloutHeader: #"{"type":"session_meta","payload":{"id":"019a-77bc-1234","cwd":"/x"}}"#), "019a-77bc-1234")
    }
}

final class AccountFilesTests: XCTestCase {
    func testClaudeStateKeepsSetupNotIdentity() {
        for key in ["mcpServers", "projects", "hasCompletedOnboarding", "hasSeenTasksHint", "opus45MigrationComplete", "bypassPermissionsModeAccepted"] {
            XCTAssertTrue(ClaudeAuthEnv.sharedStateKey(key), key)
        }
        for key in ["oauthAccount", "userID", "s1mAccessCache", "cachedUsageUtilization", "hasAvailableSubscription", "customApiKeyResponses"] {
            XCTAssertFalse(ClaudeAuthEnv.sharedStateKey(key), key)
        }
    }

    func testCodexConfigOverridesTopLevelOnly() {
        let toml = """
            model = "gpt-6-astra"
            cli_auth_credentials_store = "keyring"

            [mcp_servers.consult]
            command = "node"
            sqlite_home = "/table/value/stays"
            """
        let out = CodexConfig.forAccount(toml, sqliteHome: "/Users/sam/.codex")
        XCTAssertTrue(out.contains(#"cli_auth_credentials_store = "file""#))
        XCTAssertFalse(out.contains(#"cli_auth_credentials_store = "keyring""#))
        XCTAssertTrue(out.contains(#"sqlite_home = "/Users/sam/.codex""#))
        XCTAssertTrue(out.contains(#"sqlite_home = "/table/value/stays""#))
        XCTAssertTrue(out.contains(#"model = "gpt-6-astra""#))
        let firstTable = out.range(of: "[mcp_servers.consult]")!.lowerBound
        XCTAssertLessThan(out.range(of: "cli_auth_credentials_store")!.lowerBound, firstTable)
    }
}

final class ReviewFixTests: XCTestCase {
    func testCodexPromptsOfAnyShapeStillResume() {
        XCTAssertEqual(AgentResume.codexCommandLine(userArgs: ["fix", "the", "bug"], sessionID: "abc-123-def"), "command codex resume abc-123-def")
        XCTAssertEqual(AgentResume.codexCommandLine(userArgs: ["hello"], sessionID: "abc-123-def", prompt: "Continue where you left off."),
                       #"command codex resume abc-123-def Continue\ where\ you\ left\ off."#)
        XCTAssertNil(AgentResume.codexCommandLine(userArgs: ["review"], sessionID: "abc-123-def"))
    }

    func testClaudePromptGoesRightAfterTheSession() {
        let line = AgentResume.commandLine(argv: ["claude", "--add-dir", "/x", "--model", "opus"], claudeSessionID: "abc-123-def", prompt: "Go on")
        XCTAssertEqual(line, #"command claude --resume abc-123-def Go\ on --add-dir /x --model opus"#)
    }

    func testLimitTimestamp() {
        let line = #"{"type":"assistant","timestamp":"2026-10-25T17:00:00.123Z","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"message":{"content":[{"type":"text","text":"x"}]}}"#
        XCTAssertNotNil(LimitDetector.claude(line: line)?.timestamp)
    }

    func testCodexConfigDropsKeys() {
        let toml = "model = \"x\"\n[model_providers.mine]\napi_key = \"sk-secret\"\nbase_url = \"https://example.com\""
        let out = CodexConfig.forAccount(toml, sqliteHome: "/h")
        XCTAssertFalse(out.contains("sk-secret"))
        XCTAssertTrue(out.contains("base_url"))
    }

    func testSignedOutLoginIsNeverPicked() {
        let now = Date()
        let candidates = [AccountPicker.Candidate(id: "a", reading: nil, failed: true), AccountPicker.Candidate(id: "b", reading: nil)]
        XCTAssertEqual(AccountPicker.next(candidates, excluding: [], now: now), "b")
        XCTAssertNil(AccountPicker.next([candidates[0]], excluding: [], now: now))
    }

    func testTitleMovingAfterInterruptMeansStillWorking() {
        var s = StatusSignals()
        let start = Date()
        s.agentBusy = true
        s.lastBusyChange = start
        s.lastInterrupt = start.addingTimeInterval(2)
        XCTAssertFalse(StatusRules.isWorking(s, now: start.addingTimeInterval(3)))
        s.lastTitleChange = start.addingTimeInterval(4)
        XCTAssertTrue(StatusRules.isWorking(s, now: start.addingTimeInterval(5)))
    }
}
