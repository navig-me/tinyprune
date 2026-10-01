#if canImport(XCTest)
import CoreServices
import Foundation
import XCTest
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence


final class ManagedRootIndexerTests: XCTestCase {
    func testFSEventStreamDeliversCreatedFilePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-FSEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("created.tmp")
        let observed = expectation(description: "FSEvents reports a file created under the managed root")
        let stream = try ManagedRootEventStream(rootPath: root.path, latency: 0.05) { event in
            if event.paths.contains(where: { $0.hasSuffix("/created.tmp") }) { observed.fulfill() }
        }
        defer { stream.stop() }

        try Data("event fixture".utf8).write(to: file)
        await fulfillment(of: [observed], timeout: 5)
    }
    func testInitialIndexAndPathEventsUpdateOnlyMatchingDeadlines() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.root.appendingPathComponent("old.tmp")
        try Data("metadata only".utf8).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: original.path)

        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let initialIndexed = expectation(description: "initial root scan persisted candidate deadlines")
        initialIndexed.assertForOverFulfill = false
        let indexer = ManagedRootIndexer(store: store) {
            Task {
                if let deadlines = try? await store.upcomingDeadlines(), !deadlines.isEmpty {
                    initialIndexed.fulfill()
                }
            }
        }
        defer { Task { await indexer.stop() } }

        try await indexer.start()
        await fulfillment(of: [initialIndexed], timeout: 5)
        let initial = try await store.upcomingDeadlines()
        XCTAssertEqual(initial.map(\.identity.pathHint), [original.standardizedFileURL.path])
        XCTAssertEqual(initial.first?.explanation.disposition, .preview)

        let created = fixture.root.appendingPathComponent("new.tmp")
        try Data("new metadata".utf8).write(to: created)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: created.path)
        try await indexer.processChanges(
            ManagedRootEvent(paths: [created.path], flags: [UInt32(kFSEventStreamEventFlagItemCreated)], eventIDs: [1]),
            for: root.id
        )
        let afterCreate = try await store.upcomingDeadlines()
        XCTAssertEqual(Set(afterCreate.map(\.identity.pathHint)), Set([original.standardizedFileURL.path, created.standardizedFileURL.path]))

        try FileManager.default.removeItem(at: original)
        try await indexer.processChanges(
            ManagedRootEvent(paths: [original.path], flags: [UInt32(kFSEventStreamEventFlagItemRemoved)], eventIDs: [2]),
            for: root.id
        )
        let afterDelete = try await store.upcomingDeadlines()
        XCTAssertEqual(afterDelete.map(\.identity.pathHint), [created.standardizedFileURL.path])
        await indexer.stop()
    }

    func testDueActiveDeadlineRunsFinalTrashPreflight() async throws {
        let fixture = try makeFixture()
        var trashedPath: String?
        defer {
            if let trashedPath { try? FileManager.default.removeItem(atPath: trashedPath) }
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let candidateURL = fixture.root.appendingPathComponent("old.tmp")
        try Data("active fixture".utf8).write(to: candidateURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: candidateURL.path)

        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .active)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store)
        try await indexer.start()

        let fileAccess = LocalTrashFileAccess()
        let coordinator = TrashCoordinator(
            policyStore: store,
            fileAccess: fileAccess,
            audit: store,
            clock: FixedClock(Date(timeIntervalSince1970: 10_000))
        )
        let scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: FixedClock(Date(timeIntervalSince1970: 10_000)))
        try await scheduler.runDueNow()
        await indexer.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        let events = try await store.auditEvents()
        let move = try XCTUnwrap(events.first(where: { $0.kind == .movedToTrash }))
        trashedPath = move.detail
        XCTAssertNotNil(trashedPath)
        XCTAssertTrue(events.contains(where: { $0.kind == .trashAttempted }))
        let remaining = try await store.upcomingDeadlines()
        XCTAssertTrue(remaining.isEmpty)
    }

    private func makeFixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Indexer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("state.sqlite3")
        return (root, databaseURL)
    }

    private func makeRoot(_ url: URL) throws -> ManagedRoot {
        let path = url.standardizedFileURL.path
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try ManagedRoot(displayName: url.lastPathComponent, path: path, bookmarkData: bookmark)
    }

    private func makeRule(scope: String, state: RuleState) throws -> LifetimeRule {
        try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: scope, recursive: false),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: state
        )
    }
}

private struct FixedClock: SafetyClock {
    let instant: Date
    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { instant }
}
#endif
