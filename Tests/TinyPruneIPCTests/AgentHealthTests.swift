import Testing
import Foundation
import TinyPruneDomain
@testable import TinyPruneIPC

@Suite struct AgentHealthTests {
    @Test func testHealthPayloadRoundTripsAcrossTheIPCEncoding() throws {
        let health = AgentHealth(serviceVersion: "0.1.0")
        let payload = try JSONEncoder().encode(health)
        #expect(try JSONDecoder().decode(AgentHealth.self, from: payload) == health)
    }

    @Test func testProtocolVersionIsExplicit() {
        #expect(TinyPruneAgentXPC.protocolVersion == 2)
        #expect(TinyPruneAgentXPC.machServiceName == "com.navig-me.tinyprune.agent")
    }

    @Test func policySnapshotRevisionRoundTripsAndDefaultsToZeroWhenAbsent() throws {
        let snapshot = AgentPolicySnapshot(rules: [], overrides: [], globallyPaused: false, revision: 7)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AgentPolicySnapshot.self, from: encoded).revision == 7)

        let legacy = Data(#"{"rules":[],"overrides":[],"globallyPaused":false}"#.utf8)
        #expect(try JSONDecoder().decode(AgentPolicySnapshot.self, from: legacy).revision == 0)
    }

    @Test func overviewWithoutRootStatusesDecodesAsEmpty() throws {
        let policy = AgentPolicySnapshot(rules: [], overrides: [], globallyPaused: false)
        let status = AgentRootStatus(rootID: UUID(), path: "/Users/me/Downloads", state: .bookmarkStale, detail: "stale")
        let overview = AgentOverviewSnapshot(policy: policy, upcoming: [], rootStatuses: [status])
        let decoded = try JSONDecoder().decode(AgentOverviewSnapshot.self, from: try JSONEncoder().encode(overview))
        #expect(decoded.rootStatuses == [status])
        #expect(decoded.rootStatuses.first?.id == status.rootID)

        let legacy = Data(#"{"policy":{"rules":[],"overrides":[],"globallyPaused":false},"upcoming":[]}"#.utf8)
        #expect(try JSONDecoder().decode(AgentOverviewSnapshot.self, from: legacy).rootStatuses.isEmpty)
        #expect(try JSONDecoder().decode(AgentOverviewSnapshot.self, from: legacy).reclaimed == nil)
    }

    @Test func reclaimedDTOsAndActivitySizesRoundTrip() throws {
        let day = Date(timeIntervalSince1970: 1_000)
        let summary = AgentReclaimedSummary(lifetimeItems: 3, lifetimeBytes: 4096, itemsWithKnownSize: 2, firstMovedAt: day, lastMovedAt: day, days: [AgentReclaimedDay(day: day, items: 3, bytes: 4096)], weekItems: 3, weekBytes: 4096)
        let overview = AgentOverviewSnapshot(policy: AgentPolicySnapshot(rules: [], overrides: [], globallyPaused: false), upcoming: [], reclaimed: summary)
        #expect(try JSONDecoder().decode(AgentOverviewSnapshot.self, from: JSONEncoder().encode(overview)) == overview)
        let activity = AgentActivityItem(id: UUID(), occurredAt: day, kind: .movedToTrash, detail: "/.Trash/item", bytes: 4096, itemCount: 2)
        #expect(try JSONDecoder().decode(AgentActivityItem.self, from: JSONEncoder().encode(activity)) == activity)
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","occurredAt":0,"kind":"movedToTrash","detail":"/.Trash/old"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentActivityItem.self, from: legacy)
        #expect(decoded.bytes == nil)
        #expect(decoded.itemCount == nil)
    }

    @Test func newOperationsAndFailuresSurviveTheIPCEncoding() throws {
        let root = AgentRootSummary(id: UUID(), path: "/Users/me/Downloads", name: "Downloads")
        let operations: [AgentOperation] = [
            .setItemOverrides(changes: [
                AgentItemOverrideChange(path: "/a/b", policy: .keep(protectDescendants: true)),
                AgentItemOverrideChange(path: "/a/c", policy: nil),
            ]),
            .loadRoots,
            .cancelPreview,
        ]
        for operation in operations {
            let request = AgentRequest(operation: operation)
            #expect(try JSONDecoder().decode(AgentRequest.self, from: try JSONEncoder().encode(request)) == request)
        }
        let payloads: [AgentResponsePayload] = [
            .roots([root]),
            .failure(.policyConflict),
            .failure(.rootUnavailable("/Volumes/Disk: offline")),
        ]
        for payload in payloads {
            let response = AgentResponse(payload: payload)
            #expect(try JSONDecoder().decode(AgentResponse.self, from: try JSONEncoder().encode(response)) == response)
        }
    }

    @Test func rootSummaryCarriesNoBookmarkData() throws {
        let summary = AgentRootSummary(id: UUID(), path: "/a/Downloads", name: "Downloads")
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(!json.lowercased().contains("bookmark"))
    }

    @Test func clientTimeoutAndInterruptionAreDistinctFromUnavailable() {
        #expect(AgentClientError.timedOut != .unavailable)
        #expect(AgentClientError.interrupted != .unavailable)
        #expect(AgentClientError.timedOut != .interrupted)
    }

    @Test func peerRequirementNamesATeamOrIsAbsentForUnsignedBuilds() {
        if let requirement = PeerRequirement.current() {
            #expect(requirement.contains("certificate leaf[subject.OU]"))
        }
    }
}
