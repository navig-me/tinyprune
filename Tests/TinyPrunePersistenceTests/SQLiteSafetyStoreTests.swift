#if canImport(XCTest)
import Foundation
import XCTest
@testable import TinyPruneDomain
@testable import TinyPruneEngine
@testable import TinyPrunePersistence

final class SQLiteSafetyStoreTests: XCTestCase {
    func testSnapshotPersistsAndFailedReplacementRollsBack() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule(name: "Original")
        let keep = ItemPolicyOverride(path: "/Developer/safe", policy: .keep(protectDescendants: true))
        let snapshot = PolicySnapshot(rules: [rule], overrides: [keep], globallyPaused: true)
        try await harness.store.replaceSnapshot(snapshot)

        let loaded = try await harness.store.loadSnapshot()
        XCTAssertEqual(loaded.rules, [rule])
        XCTAssertEqual(loaded.overrides, [keep])
        XCTAssertTrue(loaded.globallyPaused)

        let duplicate = try makeRule(id: rule.id, name: "Duplicate")
        do {
            try await harness.store.replaceSnapshot(PolicySnapshot(rules: [rule, duplicate], overrides: [], globallyPaused: false))
            XCTFail("Duplicate rule IDs must fail the transaction")
        } catch {}

        let afterRollback = try await harness.store.loadSnapshot()
        XCTAssertEqual(afterRollback.rules, [rule])
        XCTAssertEqual(afterRollback.overrides, [keep])
        XCTAssertTrue(afterRollback.globallyPaused)
        let events = try await harness.store.auditEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .policyReplaced)
    }

    func testAuditEventsAreDurableAndOrderedNewestFirst() async throws {
        let harness = try makeStore()
        let identity = makeIdentity()
        let older = TrashAuditEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, occurredAt: Date(timeIntervalSince1970: 10), kind: .previewSkipped, identity: identity, ruleID: nil)
        let newer = TrashAuditEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!, occurredAt: Date(timeIntervalSince1970: 20), kind: .movedToTrash, identity: identity, ruleID: UUID(), detail: "/.Trash/file")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.store.append(older)
        try await harness.store.append(newer)
        let events = try await harness.store.auditEvents()

        XCTAssertEqual(events, [newer, older])
        do {
            try await harness.store.append(older)
            XCTFail("Duplicate audit IDs must be rejected")
        } catch {}
    }

    func testDeadlineIndexReturnsEarliestAndReplacesByStableIdentity() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let firstIdentity = makeIdentity(resource: Data([1]), path: "/Developer/first.zip")
        let renamedIdentity = makeIdentity(resource: Data([1]), path: "/Archive/first.zip")
        let secondIdentity = makeIdentity(resource: Data([2]), path: "/Developer/second.zip")
        let firstRule = try makeRule(name: "First")
        let secondRule = try makeRule(name: "Second")
        let firstExplanation = CandidateExplanation(
            candidate: RuleCandidate(identity: firstIdentity, name: "first.zip", kind: .file, timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 1))),
            rule: firstRule,
            basisDate: Date(timeIntervalSince1970: 1),
            eligibleAt: Date(timeIntervalSince1970: 11),
            scheduledAt: Date(timeIntervalSince1970: 11),
            disposition: .active
        )
        let secondExplanation = CandidateExplanation(
            candidate: RuleCandidate(identity: secondIdentity, name: "second.zip", kind: .file, timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 2))),
            rule: secondRule,
            basisDate: Date(timeIntervalSince1970: 2),
            eligibleAt: Date(timeIntervalSince1970: 22),
            scheduledAt: Date(timeIntervalSince1970: 22),
            disposition: .active
        )
        try await harness.store.saveDeadline(PersistedDeadline(identity: firstIdentity, scheduledAt: firstExplanation.scheduledAt, explanation: firstExplanation))
        try await harness.store.saveDeadline(PersistedDeadline(identity: secondIdentity, scheduledAt: secondExplanation.scheduledAt, explanation: secondExplanation))

        let renamedExplanation = CandidateExplanation(
            candidate: RuleCandidate(identity: renamedIdentity, name: "first.zip", kind: .file, timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 3))),
            rule: firstRule,
            basisDate: Date(timeIntervalSince1970: 3),
            eligibleAt: Date(timeIntervalSince1970: 33),
            scheduledAt: Date(timeIntervalSince1970: 33),
            disposition: .active
        )
        try await harness.store.saveDeadline(PersistedDeadline(identity: renamedIdentity, scheduledAt: renamedExplanation.scheduledAt, explanation: renamedExplanation))

        let next = try await harness.store.nextDeadline()
        XCTAssertEqual(next?.identity.resourceIdentifier, Data([2]))
        XCTAssertEqual(next?.scheduledAt, Date(timeIntervalSince1970: 22))
        try await harness.store.removeDeadline(for: secondIdentity)
        let nextAfterRemoval = try await harness.store.nextDeadline()
        XCTAssertEqual(nextAfterRemoval?.scheduledAt, Date(timeIntervalSince1970: 33))
    }

    private func makeStore() throws -> (directory: URL, store: SQLiteSafetyStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-SQLite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        return (directory, store)
    }

    private func makeRule(id: UUID = UUID(), name: String) throws -> LifetimeRule {
        try LifetimeRule(
            id: id,
            name: name,
            scope: RuleScope(path: "/Developer", recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: ["*.zip"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 86_400),
            action: .trashItem,
            state: .preview
        )
    }

    private func makeIdentity(resource: Data = Data([9]), path: String = "/Developer/file.zip") -> FilesystemIdentity {
        FilesystemIdentity(volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, resourceIdentifier: resource, pathHint: path)
    }
}
#endif
