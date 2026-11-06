import XCTest
@testable import AgTermCore

/// Teams usage split by login: identity hashes shared with agmux, span lookup, and the
/// per-login buckets (agmux docs/teams-usage-by-login.md).
final class TeamsLoginTests: XCTestCase {
    private let uuid = "00000000-0000-4000-8000-000000000001"

    private func ts(_ s: String) -> Date { TeamsTime.parse(s) ?? .distantPast }
    private func ms(_ s: String) -> Int64 { Int64(ts(s).timeIntervalSince1970 * 1000) }

    private func ev(_ at: String, session: String = "s1", provider: String = "ClaudeCode", tokensIn: Int = 0) -> UsageEvent {
        var e = UsageEvent(at: ts(at), provider: provider, model: "opus-5", projectKey: "helios-api", sessionID: session)
        e.tokensIn = tokensIn
        return e
    }

    // MARK: Identity hashes (expected values from agmux's Rust: serde_json + sha2)

    func testClaudeHashMatchesAgmuxIncludingSlashQuoteAndNonASCII() throws {
        let identity = try XCTUnwrap(LoginIdentity.claudeIdentity(oauthAccount: ["accountUuid": uuid, "organizationUuid": "org/é\"x"]))
        XCTAssertEqual(identity, #"claude:account-org:["00000000-0000-4000-8000-000000000001","org/é\"x"]"#)
        XCTAssertEqual(LoginIdentity.claudeHash(identity: identity), "50ce3cee6e148a4ff519fb6e001851821c5c472102490285f04354fe1989fcd3")
    }

    /// The same vectors agmux pins in `activity.rs` `claude_hash_contract_vectors`.
    func testClaudeHashMatchesAgmuxContractVectors() throws {
        let account = try XCTUnwrap(LoginIdentity.claudeIdentity(oauthAccount: ["accountUuid": uuid, "organizationUuid": "org-example"]))
        XCTAssertEqual(LoginIdentity.claudeHash(identity: account), "16605ac4757244e77aa72283fbe8bee396257c66fe1171694ded5ca8cdd60f53")
        let email = try XCTUnwrap(LoginIdentity.claudeIdentity(oauthAccount: ["emailAddress": "name@example.com", "organizationUuid": "org-example"]))
        XCTAssertEqual(LoginIdentity.claudeHash(identity: email), "5e0ed78b11a6da6d2e5f9d0fe0de3c50ba4c7f1c7bf777ea49903b9fa29ab391")
    }

    func testClaudeFallsBackToLowercasedEmailAndOrg() throws {
        let identity = try XCTUnwrap(LoginIdentity.claudeIdentity(oauthAccount: ["emailAddress": "Someone@Example.com", "organizationUuid": "org-1"]))
        XCTAssertEqual(LoginIdentity.claudeHash(identity: identity), "349e1b068776ac50afd332b52c016f69556d440d31b29043da0a5a66452c4f5e")
    }

    func testClaudeNeedsAnOrgAndRejectsPaddedValuesLikeAgmux() {
        XCTAssertNil(LoginIdentity.claudeIdentity(oauthAccount: ["accountUuid": uuid, "emailAddress": "a@example.com"]))
        XCTAssertNil(LoginIdentity.claudeIdentity(oauthAccount: ["accountUuid": " \(uuid)", "organizationUuid": " org-1"]))
    }

    func testClaudeConfigFileGivesHashAndEmail() throws {
        let data = Data(#"{"oauthAccount":{"accountUuid":"00000000-0000-4000-8000-000000000001","organizationUuid":"org/é\"x","emailAddress":"someone@example.com"}}"#.utf8)
        let login = try XCTUnwrap(LoginIdentity.claude(configJSON: data))
        XCTAssertEqual(login.hash, "50ce3cee6e148a4ff519fb6e001851821c5c472102490285f04354fe1989fcd3")
        XCTAssertEqual(login.label, "someone@example.com")
        XCTAssertNil(LoginIdentity.claude(configJSON: Data(#"{"numStartups":3}"#.utf8)))
    }

    func testCodexHashIsWorkspacePlusSeatLikeThePool() throws {
        let jwt = "e30.eyJzdWIiOiAidXNlci1zZWF0LzEiLCAiZW1haWwiOiAieEBleGFtcGxlLmNvbSJ9.sig"
        let auth = Data(#"{"tokens":{"account_id":"workspace-1","id_token":"\#(jwt)"}}"#.utf8)
        XCTAssertEqual(LoginIdentity.codexHash(authJSON: auth), "0951b9db39aa0e5516bcb3373963f2cdbffa581f5fc257e4a540887c2e17383d")
        XCTAssertNil(LoginIdentity.codexHash(authJSON: Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8)))
    }

    func testCompactJSONEscapesLikeSerde() {
        XCTAssertEqual(LoginIdentity.compactJSON(["a/b", "q\"", "\\", "\n\t\u{01}"]), #"["a/b","q\"","\\","\n\t\u0001"]"#)
    }

    // MARK: Spans

    func testEventGoesToTheLatestSpanStartedByThen() {
        let index = LoginSpanIndex([
            LoginSpan(provider: "claude", sessionID: "s1", identityHash: "b", label: nil, fromMs: ms("2026-11-06T11:00:00Z")),
            LoginSpan(provider: "claude", sessionID: "s1", identityHash: "a", label: nil, fromMs: ms("2026-11-06T10:00:00Z")),
        ])
        XCTAssertNil(index.span(provider: "claude", sessionID: "s1", atMs: ms("2026-11-06T09:59:59Z")))
        XCTAssertEqual(index.span(provider: "claude", sessionID: "s1", atMs: ms("2026-11-06T10:30:00Z"))?.identityHash, "a")
        XCTAssertEqual(index.span(provider: "claude", sessionID: "s1", atMs: ms("2026-11-06T11:00:00Z"))?.identityHash, "b")
        XCTAssertNil(index.span(provider: "codex", sessionID: "s1", atMs: ms("2026-11-06T11:30:00Z")))
    }

    // MARK: Folding

    func testSwitchMidSessionSplitsTokensAndActiveTimeAndLeavesEarlierWorkOut() {
        let spans = LoginSpanIndex([
            LoginSpan(provider: "claude", sessionID: "s1", identityHash: "own", label: nil, fromMs: ms("2026-11-06T10:00:00Z")),
            LoginSpan(provider: "claude", sessionID: "s1", identityHash: "shared", label: nil, fromMs: ms("2026-11-06T10:10:00Z")),
        ])
        let events = [
            ev("2026-11-06T09:58:00Z", tokensIn: 7),   // before agterm recorded a login
            ev("2026-11-06T10:01:00Z", tokensIn: 100),
            ev("2026-11-06T10:03:00Z", tokensIn: 50),
            ev("2026-11-06T10:11:00Z", tokensIn: 20),
            ev("2026-11-06T10:12:00Z", tokensIn: 5),
        ]
        let buckets = TeamsAggregator.accountBuckets(events: events, spans: spans, now: ts("2026-11-06T12:00:00Z"))
        XCTAssertEqual(buckets.map(\.identityHash), ["own", "shared"])
        XCTAssertEqual(buckets.map(\.tokensIn), [150, 25])
        XCTAssertEqual(buckets.map(\.provider), ["claude", "claude"])
        XCTAssertEqual(buckets.map(\.hourUtc), ["2026-11-06T10", "2026-11-06T10"])
        // own: 10:01→10:03 (2 min) + 10:03→10:08 (gap capped at 5 min); shared: 10:11→10:12 + 30 s tail.
        XCTAssertEqual(buckets[0].activeMs, 7 * 60_000)
        XCTAssertEqual(buckets[1].activeMs, 60_000 + 30_000)
    }

    func testActiveTimeCrossingAnHourSplitsAndCodexUsesItsRolloutName() {
        let session = "rollout-2026-11-06T10-58-00-abc"
        let spans = LoginSpanIndex([LoginSpan(provider: "codex", sessionID: session, identityHash: "pool", label: nil, fromMs: ms("2026-11-06T10:00:00Z"))])
        var a = ev("2026-11-06T10:59:00Z", session: session, provider: "Codex", tokensIn: 3)
        a.reasoning = 2
        a.isTurn = true
        let b = ev("2026-11-06T11:01:00Z", session: session, provider: "Codex", tokensIn: 4)
        let buckets = TeamsAggregator.accountBuckets(events: [a, b], spans: spans, now: ts("2026-11-06T12:00:00Z"))
        XCTAssertEqual(buckets.map(\.hourUtc), ["2026-11-06T10", "2026-11-06T11"])
        XCTAssertEqual(buckets.map(\.activeMs), [60_000, 60_000 + 30_000])
        XCTAssertEqual(buckets.map(\.tokensIn), [3, 4])
        XCTAssertEqual(buckets[0].tokensReasoning, 2)
        XCTAssertEqual(buckets[0].turns, 1)
    }

    func testUnsplitProvidersFutureEventsAndUnknownSessionsAreLeftOut() {
        let spans = LoginSpanIndex([LoginSpan(provider: "claude", sessionID: "s1", identityHash: "own", label: nil, fromMs: 0)])
        let events = [ev("2026-11-06T10:00:00Z", provider: "Grok", tokensIn: 1),
                      ev("2026-11-06T13:00:00Z", tokensIn: 1),
                      ev("2026-11-06T10:00:00Z", session: "other", tokensIn: 1)]
        XCTAssertTrue(TeamsAggregator.accountBuckets(events: events, spans: spans, now: ts("2026-11-06T12:00:00Z")).isEmpty)
    }

    func testAccountBucketsAddUpToTheRegularBucketsWhenEverythingIsAttributed() {
        let spans = LoginSpanIndex([LoginSpan(provider: "claude", sessionID: "s1", identityHash: "own", label: nil, fromMs: 0)])
        var events = [ev("2026-11-06T10:01:00Z", tokensIn: 10), ev("2026-11-06T10:20:00Z", tokensIn: 30)]
        events[1].costUSD = 0.5
        events[1].costIncomplete = true
        let now = ts("2026-11-06T12:00:00Z")
        let regular = TeamsAggregator.buckets(events: events, now: now, timeZone: .current)
        let split = TeamsAggregator.accountBuckets(events: events, spans: spans, now: now)
        XCTAssertEqual(split.map(\.tokensIn).reduce(0, +), regular.map(\.tokensIn).reduce(0, +))
        XCTAssertEqual(split.map(\.activeMs).reduce(0, +), regular.map(\.activeMs).reduce(0, +))
        XCTAssertEqual(split.first?.costUsd, 0.5)
        XCTAssertEqual(split.first?.costIncomplete, true)
    }

    // MARK: Wire

    func testAccountBucketEncodesTheContractFields() throws {
        var b = AccountBucket()
        (b.hourUtc, b.provider, b.identityHash, b.tokensIn, b.costIncomplete) = ("2026-11-06T14", "claude", String(repeating: "a", count: 64), 5, true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["hourUtc", "provider", "identityHash", "tokensIn", "tokensOut", "tokensCacheRead",
                                          "tokensCacheWrite", "tokensReasoning", "costUsd", "costIncomplete", "activeMs", "turns"])
        XCTAssertEqual(object["costIncomplete"] as? Bool, true)
    }

    func testLabelsAreClaudeOnlyNewestPerLoginAndCapped() {
        var spans = [
            LoginSpan(provider: "claude", sessionID: "s1", identityHash: "h1", label: "old@example.com", fromMs: 1),
            LoginSpan(provider: "claude", sessionID: "s2", identityHash: "h1", label: "new@example.com", fromMs: 2),
            LoginSpan(provider: "claude", sessionID: "s3", identityHash: "h2", label: nil, fromMs: 3),
            LoginSpan(provider: "codex", sessionID: "r1", identityHash: "h3", label: "x@example.com", fromMs: 4),
        ]
        XCTAssertEqual(AccountLabel.from(spans), [AccountLabel(provider: "claude", identityHash: "h1", label: "new@example.com")])
        spans = (0..<80).map { LoginSpan(provider: "claude", sessionID: "s\($0)", identityHash: "h\($0)", label: "u\($0)@example.com", fromMs: Int64($0)) }
        XCTAssertEqual(AccountLabel.from(spans).count, AccountLabel.maxPerUpload)
        XCTAssertEqual(AccountLabel.from(spans).first?.identityHash, "h79")
    }
}
