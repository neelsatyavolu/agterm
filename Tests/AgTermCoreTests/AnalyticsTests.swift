import Foundation
import XCTest
@testable import AgTermCore

final class AnalyticsTests: XCTestCase {
    private let installID = "7d444840-9dc0-41a6-9a5e-6c0b2c8d1f3e"

    /// Records what the client hands its transport.
    private final class FakeTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [(path: String, body: Data)] = []
        var sent: [(path: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return _sent }

        var transport: AnalyticsClient.Transport {
            { path, body, done in
                self.lock.lock()
                self._sent.append((path, body))
                self.lock.unlock()
                done()
            }
        }
    }

    private final class Flag: @unchecked Sendable { var on = true }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func client(_ fake: FakeTransport, allowed: Flag = Flag()) -> AnalyticsClient {
        AnalyticsClient(installID: installID, isAllowed: { allowed.on }, transport: fake.transport)
    }

    // MARK: Events and the allow-list

    func testAgentStartedOnlyForKnownAgents() {
        XCTAssertEqual(AnalyticsEvent.agentStarted("claude"), AnalyticsEvent(name: "agent_started", props: ["agent": "claude"]))
        XCTAssertEqual(AnalyticsEvent.agentStarted("cursor-agent")?.props, ["agent": "cursor-agent"])
        XCTAssertNil(AnalyticsEvent.agentStarted("my-secret-script"))
        XCTAssertNil(AnalyticsEvent.agentStarted(""))
    }

    func testEveryAgentIDFitsTheServerLimit() {
        for kind in AgentKind.all {
            XCTAssertNotNil(AnalyticsEvent.agentStarted(kind.id))
            XCTAssertLessThanOrEqual(kind.id.count, 32)
        }
    }

    /// The analytics service drops agents and features it doesn't list. docs/analytics-allowlist.json
    /// is what `scripts/analytics-sync.sh` (run by every release) writes into the service, so a
    /// new AgentKind or AnalyticsFeature fails here until it's added to that file.
    func testAllowListFileMatchesAgentsAndFeatures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/analytics-allowlist.json")
        let list = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        XCTAssertEqual(list["agents"], AgentKind.all.map(\.id))
        XCTAssertEqual(list["features"], AnalyticsFeature.allCases.map(\.rawValue))
    }

    func testFeatureEvent() {
        XCTAssertEqual(AnalyticsEvent.featureUsed(.split), AnalyticsEvent(name: "feature_used", props: ["feature": "split"]))
    }

    func testUpdateInstalledOnlyWhenTheVersionChanged() {
        XCTAssertEqual(AnalyticsEvent.updateInstalled(previous: "1.1.7", current: "1.1.8"), .featureUsed(.updateInstalled))
        XCTAssertNil(AnalyticsEvent.updateInstalled(previous: nil, current: "1.1.8"), "first launch is not an update")
        XCTAssertNil(AnalyticsEvent.updateInstalled(previous: "1.1.8", current: "1.1.8"))
    }

    // MARK: Encoding

    func testHeartbeatEncoding() throws {
        let beat = AnalyticsHeartbeat(appVersion: "1.1.8", osVersion: "26.1.0", arch: "arm64")
        let body = try json(AnalyticsPayload.heartbeat(installID: installID, beat))
        XCTAssertEqual(body as NSDictionary, [
            "install_id": installID, "app": "agterm", "app_version": "1.1.8",
            "os_name": "macos", "os_version": "26.1.0", "arch": "arm64", "channel": "release",
        ] as NSDictionary)
    }

    func testEventsEncoding() throws {
        let body = try json(AnalyticsPayload.events(installID: installID, [.featureUsed(.split), .agentStarted("codex")!]))
        XCTAssertEqual(body["install_id"] as? String, installID)
        XCTAssertEqual(body["app"] as? String, "agterm")
        XCTAssertEqual(body.keys.sorted(), ["app", "events", "install_id"])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0] as NSDictionary, ["name": "feature_used", "props": ["feature": "split"]] as NSDictionary)
        XCTAssertEqual(events[1] as NSDictionary, ["name": "agent_started", "props": ["agent": "codex"]] as NSDictionary)
    }

    // MARK: Install ID

    func testInstallIDIsAKeptOrFreshV4UUID() {
        XCTAssertEqual(AnalyticsInstallID.resolve(stored: installID), installID)
        XCTAssertEqual(AnalyticsInstallID.resolve(stored: installID.uppercased()), installID)
        let fresh = AnalyticsInstallID.resolve(stored: nil)
        XCTAssertTrue(AnalyticsInstallID.isValid(fresh))
        XCTAssertEqual(fresh, fresh.lowercased())
        XCTAssertNotEqual(AnalyticsInstallID.resolve(stored: "not-a-uuid"), "not-a-uuid")
        // A version 1 UUID is replaced: only random ids are accepted.
        XCTAssertFalse(AnalyticsInstallID.isValid("550e8400-e29b-11d4-a716-446655440000"))
    }

    // MARK: Gating

    func testGateNeverSendsFromDebugBuildsOrTests() {
        XCTAssertTrue(AnalyticsGate.allowsSending(optedIn: true, isReleaseBuild: true, environment: [:]))
        XCTAssertFalse(AnalyticsGate.allowsSending(optedIn: false, isReleaseBuild: true, environment: [:]))
        XCTAssertFalse(AnalyticsGate.allowsSending(optedIn: true, isReleaseBuild: false, environment: [:]))
        XCTAssertFalse(AnalyticsGate.allowsSending(optedIn: true, isReleaseBuild: true, environment: ["AGTERM_STATE_DIR": "/tmp/x"]))
        XCTAssertFalse(AnalyticsGate.allowsSending(optedIn: true, isReleaseBuild: true, environment: ["AGTERM_SELFTEST": "/tmp/x"]))
    }

    // MARK: Client

    func testRecordQueuesAndFlushSendsOneBatch() throws {
        let fake = FakeTransport()
        let analytics = client(fake)
        analytics.record(.featureUsed(.split))
        analytics.record(.agentStarted("claude"))
        analytics.record(.agentStarted("not-an-agent"))
        XCTAssertTrue(fake.sent.isEmpty, "nothing goes out until a flush")
        XCTAssertEqual(analytics.queuedCount, 2)

        XCTAssertTrue(analytics.flush())
        XCTAssertEqual(fake.sent.count, 1)
        XCTAssertEqual(fake.sent[0].path, "/v1/events")
        XCTAssertEqual((try json(fake.sent[0].body)["events"] as? [Any])?.count, 2)
        XCTAssertEqual(analytics.queuedCount, 0)

        XCTAssertFalse(analytics.flush(), "an empty queue sends nothing")
        XCTAssertEqual(fake.sent.count, 1)
    }

    func testFlushCallsDoneEvenWhenNothingIsSent() {
        let fake = FakeTransport()
        let analytics = client(fake)
        let done = expectation(description: "done")
        XCTAssertFalse(analytics.flush { done.fulfill() })
        wait(for: [done], timeout: 1)
    }

    func testQueueIsCapped() {
        let fake = FakeTransport()
        let analytics = client(fake)
        for _ in 0..<(AnalyticsClient.maxQueued + 25) { analytics.record(.featureUsed(.split)) }
        XCTAssertEqual(analytics.queuedCount, AnalyticsClient.maxQueued)
    }

    func testOptedOutRecordsAndSendsNothing() {
        let fake = FakeTransport()
        let allowed = Flag()
        allowed.on = false
        let analytics = client(fake, allowed: allowed)
        analytics.sendHeartbeat(AnalyticsHeartbeat(appVersion: "1.1.8", osVersion: "26.1", arch: "arm64"))
        analytics.record(.featureUsed(.split))
        XCTAssertEqual(analytics.queuedCount, 0)
        XCTAssertFalse(analytics.flush())
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testOptingOutDropsWhatWasQueued() {
        let fake = FakeTransport()
        let allowed = Flag()
        let analytics = client(fake, allowed: allowed)
        analytics.record(.featureUsed(.cloudTab))
        allowed.on = false
        XCTAssertFalse(analytics.flush())
        XCTAssertEqual(analytics.queuedCount, 0)
        allowed.on = true
        XCTAssertFalse(analytics.flush(), "turning it back on doesn't bring old events back")
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testHeartbeatGoesOutRightAway() throws {
        let fake = FakeTransport()
        client(fake).sendHeartbeat(AnalyticsHeartbeat(appVersion: "1.1.8", osVersion: "26.1", arch: "x86_64"))
        XCTAssertEqual(fake.sent.map(\.path), ["/v1/heartbeat"])
        XCTAssertEqual(try json(fake.sent[0].body)["arch"] as? String, "x86_64")
    }

    func testEndpointIsAgmuxAnalytics() {
        XCTAssertEqual(AnalyticsClient.baseURL.absoluteString, "https://owner.agmux.dev")
    }
}
