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
        #expect(healthDTO.serviceVersion == "0.1.3")

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
    @Test func staleRevisionIsRejectedAndFreshRevisionAdvances() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let first = try await loadPolicy(harness.handler)
        let replacement = AgentPolicySnapshot(rules: [try makeRule()], overrides: [], managedRoots: [root], globallyPaused: false, revision: first.revision)

        let applied = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(replacement)))
        #expect(applied.payload == .acknowledged)
        let second = try await loadPolicy(harness.handler)
        #expect(second.revision > first.revision)

        // A client that still holds the first revision must not overwrite the newer policy.
        let stale = AgentPolicySnapshot(rules: [], overrides: [], managedRoots: [], globallyPaused: true, revision: first.revision)
        let rejected = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(stale)))
        #expect(rejected.payload == .failure(.policyConflict))
        let unchanged = try await loadPolicy(harness.handler)
        #expect(unchanged.rules == replacement.rules)
        #expect(!unchanged.globallyPaused)
        #expect(unchanged.revision == second.revision)
    }

    @Test func concurrentReplacementsFromTheSameRevisionApplyExactlyOnce() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let base = try await loadPolicy(harness.handler).revision
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let handler = harness.handler
        let requests = try (0..<4).map { _ in
            AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [try makeRule()], overrides: [], managedRoots: [root], globallyPaused: false, revision: base)))
        }
        var payloads: [AgentResponsePayload] = []
        try await withThrowingTaskGroup(of: AgentResponsePayload.self) { group in
            for request in requests { group.addTask { try await self.response(from: handler, request: request).payload } }
            for try await payload in group { payloads.append(payload) }
        }
        #expect(payloads.filter { $0 == .acknowledged }.count == 1)
        #expect(payloads.filter { $0 == .failure(.policyConflict) }.count == 3)
    }

    @Test func policyPausedUntilSurvivesRoundTripWithItsRevision() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let until = Date().addingTimeInterval(3_600)
        _ = try await response(from: harness.handler, request: AgentRequest(operation: .pauseUntil(until)))
        let loaded = try await loadPolicy(harness.handler)
        let resent = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(loaded)))
        #expect(resent.payload == .acknowledged)
        let after = try await loadPolicy(harness.handler)
        #expect(after.globallyPaused)
        #expect(after.pausedUntil != nil)
    }

    @Test func handlerStampsAuditEventsWithTheInjectedClock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FixedClock(fixed)
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"), clock: clock)
        let handler = AgentRequestHandler(store: store, clock: clock)
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let rule = try makeRule()
        let base = try await loadPolicy(handler).revision
        _ = try await response(from: handler, request: AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false, revision: base))))
        _ = try await response(from: handler, request: AgentRequest(operation: .deleteRule(rule.id)))

        let events = try await store.auditEvents()
        #expect(events.contains { $0.kind == .ruleCreated })
        #expect(events.contains { $0.kind == .ruleDeleted })
        #expect(events.allSatisfy { $0.occurredAt == fixed })
    }

    @Test func activeRuleOnVeryBroadScopeIsRejectedButPreviewIsAllowed() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let broad = try LifetimeRule(
            name: "Everything in Users",
            scope: RuleScope(path: "/Users", recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 86_400),
            action: .trashItem,
            state: .active,
            matchMode: .template
        )
        let base = try await loadPolicy(harness.handler).revision
        let rejected = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [broad], overrides: [], globallyPaused: false, revision: base))))
        guard case .failure(.invalidRequest) = rejected.payload else { Issue.record("Active very-broad rule must be rejected"); return }

        let saved = try await response(from: harness.handler, request: AgentRequest(operation: .saveRule(rule: broad, roots: nil, keepPaths: [], unkeepPaths: [], revision: base)))
        guard case .failure(.invalidRequest) = saved.payload else { Issue.record("saveRule must reject active very-broad rules"); return }
        #expect(try await loadPolicy(harness.handler).rules.isEmpty)
    }

    @Test func saveRuleIsAtomicAndRejectsStaleRevisionAndKeepOutsideRoots() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let rule = try makeRule()
        let base = try await loadPolicy(harness.handler).revision

        // Keep path cannot be resolved (no runtime) -> nothing at all is saved, not even the rule.
        let failing = try await response(from: harness.handler, request: AgentRequest(operation: .saveRule(
            rule: rule, roots: [root], keepPaths: ["/Downloads/keep-me"], unkeepPaths: [], revision: base)))
        guard case .failure(.invalidRequest) = failing.payload else { Issue.record("Unresolvable keep path must fail the whole save"); return }
        let afterFailure = try await loadPolicy(harness.handler)
        #expect(afterFailure.rules.isEmpty)
        #expect(afterFailure.managedRoots.isEmpty)
        #expect(afterFailure.revision == base)

        let saved = try await response(from: harness.handler, request: AgentRequest(operation: .saveRule(
            rule: rule, roots: [root], keepPaths: [], unkeepPaths: [], revision: base)))
        #expect(saved.payload == .acknowledged)
        let afterSave = try await loadPolicy(harness.handler)
        #expect(afterSave.rules == [rule])
        #expect(afterSave.managedRoots == [root])
        #expect(afterSave.revision > base)

        let stale = try await response(from: harness.handler, request: AgentRequest(operation: .saveRule(
            rule: rule, roots: nil, keepPaths: [], unkeepPaths: [], revision: base)))
        #expect(stale.payload == .failure(.policyConflict))
    }

    @Test func overrideOnTheManagedRootItselfAndMalformedPathsAreRejected() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let base = try await loadPolicy(harness.handler).revision
        _ = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: false, revision: base))))

        for path in ["/Downloads", "/Downloads/../etc", "relative/path", "/Elsewhere/file"] {
            let result = try await response(from: harness.handler, request: AgentRequest(operation: .setItemOverride(path: path, policy: .keep(protectDescendants: true))))
            guard case .failure(.invalidRequest) = result.payload else { Issue.record("Override at \(path) must be rejected"); return }
        }
        let batched = try await response(from: harness.handler, request: AgentRequest(operation: .setItemOverrides(changes: [
            AgentItemOverrideChange(path: "/Downloads", policy: .keep(protectDescendants: true)),
        ])))
        guard case .failure(.invalidRequest) = batched.payload else { Issue.record("Batched override on the root must be rejected"); return }
        #expect(try await loadPolicy(harness.handler).overrides.isEmpty)
    }

    @Test func clearingAnAbsentOverrideIsANoOpWithoutAuditNoise() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let root = try ManagedRoot(displayName: "Downloads", path: "/Downloads", bookmarkData: Data([1]))
        let base = try await loadPolicy(harness.handler).revision
        _ = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: false, revision: base))))
        let before = try await harness.store.auditEvents().count

        let cleared = try await response(from: harness.handler, request: AgentRequest(operation: .setItemOverrides(changes: [
            AgentItemOverrideChange(path: "/Downloads/old.zip", policy: nil),
        ])))
        #expect(cleared.payload == .acknowledged)
        #expect(try await harness.store.auditEvents().count == before)

        let outside = try await response(from: harness.handler, request: AgentRequest(operation: .clearItemOverride(path: "/Elsewhere/old.zip")))
        guard case .failure(.invalidRequest) = outside.payload else { Issue.record("Clearing outside managed roots must be rejected"); return }
    }

    @Test func loadRootsReturnsNamesWithoutBookmarkData() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let root = try ManagedRoot(displayName: "Downloads", path: "/Users/me/Downloads", bookmarkData: Data([9, 9, 9]))
        let base = try await loadPolicy(harness.handler).revision
        _ = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: false, revision: base))))

        let data = try JSONEncoder().encode(AgentRequest(operation: .loadRoots))
        let raw = await harness.handler.handle(data)
        #expect(!String(decoding: raw, as: UTF8.self).lowercased().contains("bookmark"))
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: raw)
        #expect(decoded.payload == .roots([AgentRootSummary(id: root.id, path: root.path, name: "Downloads")]))
    }

    @Test func cancelPreviewWithoutRuntimeIsAcknowledged() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let result = try await response(from: harness.handler, request: AgentRequest(operation: .cancelPreview))
        #expect(result.payload == .acknowledged)
    }

    private struct FixedClock: SafetyClock {
        let date: Date
        init(_ date: Date) { self.date = date }
        func now() -> Date { date }
    }

    private func loadPolicy(_ handler: AgentRequestHandler) async throws -> AgentPolicySnapshot {
        let loaded = try await response(from: handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = loaded.payload else { throw PolicyLoadFailure() }
        return snapshot
    }

    private struct PolicyLoadFailure: Error {}


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
