import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

@Suite struct AgentRequestHandlerTests {
    @Test func testHealthAndPolicyRequestsUseProtocolVersion() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let health = try await response(from: harness.handler, request: AgentRequest(operation: .health))
        #expect(health.protocolVersion == TinyPruneAgentXPC.protocolVersion)
        guard case .health(let healthDTO) = health.payload else { Issue.record("Expected health response"); return }
        #expect(healthDTO.serviceVersion == "0.1.0")

        let policy = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = policy.payload else { Issue.record("Expected policy response"); return }
        #expect(snapshot.rules.isEmpty)
        #expect(!(snapshot.globallyPaused))
    }

    @Test func testPolicyReplacementIsPersistedAndAudited() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule()
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let replacement = AgentPolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: true)

        let replaceResponse = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(replacement)))

        #expect(replaceResponse.payload == .acknowledged)
        let loaded = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = loaded.payload else { Issue.record("Expected persisted policy response"); return }
        #expect(snapshot.rules == [rule])
        #expect(snapshot.managedRoots == [root])
        #expect(snapshot.globallyPaused)
        let identity = FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([3]), pathHint: "/Downloads/archive.zip")
        let candidate = RuleCandidate(identity: identity, name: "archive.zip", kind: .file, timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 100)))
        let explanation = CandidateExplanation(candidate: candidate, rule: rule, basisDate: Date(timeIntervalSince1970: 100), eligibleAt: Date(timeIntervalSince1970: 200), scheduledAt: Date(timeIntervalSince1970: 200), disposition: .preview)
        try await harness.store.saveDeadline(PersistedDeadline(identity: identity, scheduledAt: explanation.scheduledAt, explanation: explanation))
        let overview = try await response(from: harness.handler, request: AgentRequest(operation: .loadOverview))
        guard case .overview(let overviewDTO) = overview.payload else { Issue.record("Expected Overview response"); return }
        #expect(overviewDTO.upcoming.map(\.explanation) == [explanation])
        let events = try await harness.store.auditEvents()
        #expect(Set(events.map(\.kind)) == [.policyReplaced, .globalPauseChanged, .ruleCreated])
        #expect(events.count == 3)
    }

    @Test func testMalformedAndUnsupportedRequestsReturnStructuredFailures() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let malformed = await harness.handler.handle(Data("not-json".utf8))
        let malformedResponse = try JSONDecoder().decode(AgentResponse.self, from: malformed)
        guard case .failure(.invalidRequest) = malformedResponse.payload else { Issue.record("Malformed request was not rejected"); return }

        let unsupportedRequest = AgentRequest(protocolVersion: TinyPruneAgentXPC.protocolVersion + 1, operation: .health)
        let unsupported = try await response(from: harness.handler, request: unsupportedRequest)
        guard case .failure(.unsupportedProtocol(let expected, let received)) = unsupported.payload else {
            Issue.record("Unsupported protocol was not reported"); return
        }
        #expect(expected == TinyPruneAgentXPC.protocolVersion)
        #expect(received == TinyPruneAgentXPC.protocolVersion + 1)
    }

    @Test func testInvalidPolicyMutationIsRejectedWithoutPersistence() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule()
        let duplicate = try makeRule(id: rule.id)
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let request = AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [rule, duplicate], overrides: [], managedRoots: [root], globallyPaused: true)))

        let invalidResponse = try await response(from: harness.handler, request: request)
        guard case .failure(.invalidRequest) = invalidResponse.payload else { Issue.record("Duplicate rule IDs must be rejected"); return }
        let loaded = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = loaded.payload else { Issue.record("Expected policy response"); return }
        #expect(snapshot.rules.isEmpty)
        #expect(!(snapshot.globallyPaused))
        let events = try await harness.store.auditEvents()
        #expect(events.isEmpty)
    }

    @Test func testSettingsRoundTripAndPauseUntilRejectsPastDates() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let settings = AgentSettings(defaultGracePeriodSeconds: 300, protectHiddenFiles: true, activityRetentionDays: 14)

        let updated = try await response(from: harness.handler, request: AgentRequest(operation: .updateSettings(settings)))
        #expect(updated.payload == .settings(settings))
        let loaded = try await response(from: harness.handler, request: AgentRequest(operation: .loadSettings))
        #expect(loaded.payload == .settings(settings))
        let events = try await harness.store.auditEvents()
        #expect(events.contains { $0.kind == .settingsChanged })

        let past = try await response(from: harness.handler, request: AgentRequest(operation: .pauseUntil(Date(timeIntervalSinceNow: -60))))
        guard case .failure(.invalidRequest) = past.payload else { Issue.record("Past pause end must be rejected"); return }
        let future = try await response(from: harness.handler, request: AgentRequest(operation: .pauseUntil(Date(timeIntervalSinceNow: 3_600))))
        #expect(future.payload == .acknowledged)
        let policy = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = policy.payload else { Issue.record("Expected policy response"); return }
        #expect(snapshot.globallyPaused)
        #expect(snapshot.pausedUntil != nil)
    }

    private func makeHandler() throws -> (directory: URL, store: SQLiteSafetyStore, handler: AgentRequestHandler) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        return (directory, store, AgentRequestHandler(store: store))
    }

    private func response(from handler: AgentRequestHandler, request: AgentRequest) async throws -> AgentResponse {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(AgentResponse.self, from: await handler.handle(data))
    }

    private func makeRule(id: UUID = UUID()) throws -> LifetimeRule {
        try LifetimeRule(
            id: id,
            name: "Temporary exports",
            scope: RuleScope(path: "/Downloads", recursive: false),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.zip"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 86_400),
            action: .trashItem,
            state: .preview
        )
    }
}
