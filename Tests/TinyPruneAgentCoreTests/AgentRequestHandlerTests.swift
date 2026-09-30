#if canImport(XCTest)
import Foundation
import XCTest
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

final class AgentRequestHandlerTests: XCTestCase {
    func testHealthAndPolicyRequestsUseProtocolVersion() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let health = try await response(from: harness.handler, request: AgentRequest(operation: .health))
        XCTAssertEqual(health.protocolVersion, TinyPruneAgentXPC.protocolVersion)
        guard case .health(let healthDTO) = health.payload else { return XCTFail("Expected health response") }
        XCTAssertEqual(healthDTO.serviceVersion, "0.1.0")

        let policy = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = policy.payload else { return XCTFail("Expected policy response") }
        XCTAssertTrue(snapshot.rules.isEmpty)
        XCTAssertFalse(snapshot.globallyPaused)
    }

    func testPolicyReplacementIsPersistedAndAudited() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule()
        let replacement = AgentPolicySnapshot(rules: [rule], overrides: [], globallyPaused: true)

        let replaceResponse = try await response(from: harness.handler, request: AgentRequest(operation: .replacePolicy(replacement)))

        XCTAssertEqual(replaceResponse.payload, .acknowledged)
        let loaded = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = loaded.payload else { return XCTFail("Expected persisted policy response") }
        XCTAssertEqual(snapshot.rules, [rule])
        XCTAssertTrue(snapshot.globallyPaused)
        let identity = FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([3]), pathHint: "/Downloads/archive.zip")
        let candidate = RuleCandidate(identity: identity, name: "archive.zip", kind: .file, timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 100)))
        let explanation = CandidateExplanation(candidate: candidate, rule: rule, basisDate: Date(timeIntervalSince1970: 100), eligibleAt: Date(timeIntervalSince1970: 200), scheduledAt: Date(timeIntervalSince1970: 200), disposition: .preview)
        try await harness.store.saveDeadline(PersistedDeadline(identity: identity, scheduledAt: explanation.scheduledAt, explanation: explanation))
        let overview = try await response(from: harness.handler, request: AgentRequest(operation: .loadOverview))
        guard case .overview(let overviewDTO) = overview.payload else { return XCTFail("Expected Overview response") }
        XCTAssertEqual(overviewDTO.upcoming.map(\.explanation), [explanation])
        let events = try await harness.store.auditEvents()
        XCTAssertEqual(events.map(\.kind), [.policyReplaced])
    }

    func testMalformedAndUnsupportedRequestsReturnStructuredFailures() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let malformed = await harness.handler.handle(Data("not-json".utf8))
        let malformedResponse = try JSONDecoder().decode(AgentResponse.self, from: malformed)
        guard case .failure(.invalidRequest) = malformedResponse.payload else { return XCTFail("Malformed request was not rejected") }

        let unsupportedRequest = AgentRequest(protocolVersion: TinyPruneAgentXPC.protocolVersion + 1, operation: .health)
        let unsupported = try await response(from: harness.handler, request: unsupportedRequest)
        guard case .failure(.unsupportedProtocol(let expected, let received)) = unsupported.payload else {
            return XCTFail("Unsupported protocol was not reported")
        }
        XCTAssertEqual(expected, TinyPruneAgentXPC.protocolVersion)
        XCTAssertEqual(received, TinyPruneAgentXPC.protocolVersion + 1)
    }

    func testInvalidPolicyMutationIsRejectedWithoutPersistence() async throws {
        let harness = try makeHandler()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule()
        let duplicate = try makeRule(id: rule.id)
        let request = AgentRequest(operation: .replacePolicy(AgentPolicySnapshot(rules: [rule, duplicate], overrides: [], globallyPaused: true)))

        let invalidResponse = try await response(from: harness.handler, request: request)
        guard case .failure(.invalidRequest) = invalidResponse.payload else { return XCTFail("Duplicate rule IDs must be rejected") }
        let loaded = try await response(from: harness.handler, request: AgentRequest(operation: .loadPolicy))
        guard case .policy(let snapshot) = loaded.payload else { return XCTFail("Expected policy response") }
        XCTAssertTrue(snapshot.rules.isEmpty)
        XCTAssertFalse(snapshot.globallyPaused)
        let events = try await harness.store.auditEvents()
        XCTAssertTrue(events.isEmpty)
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
#endif
