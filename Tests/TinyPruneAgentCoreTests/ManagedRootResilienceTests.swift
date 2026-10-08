import CoreServices
import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

@Suite struct ManagedRootResilienceTests {
    @Test func testSymlinkInEventBatchDoesNotAbortOtherPaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        try await store.replaceSnapshot(PolicySnapshot(rules: [try makeRule(scope: root.path)], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root })
        try await indexer.start()
        defer { Task { await indexer.stop() } }

        let target = fixture.root.appendingPathComponent("target.tmp")
        try Data("t".utf8).write(to: target)
        let link = fixture.root.appendingPathComponent("link.tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let danglingLink = fixture.root.appendingPathComponent("dangling.tmp")
        try FileManager.default.createSymbolicLink(atPath: danglingLink.path, withDestinationPath: "/nonexistent-tinyprune-target")

        let flag = UInt32(kFSEventStreamEventFlagItemCreated)
        try await indexer.processChanges(
            ManagedRootEvent(
                paths: [link.path, danglingLink.path, target.path],
                flags: [flag, flag, flag],
                eventIDs: [1, 2, 3]
            ),
            for: root.id
        )
        let indexed = try await store.upcomingDeadlines().map(\.identity.pathHint)
        #expect(indexed.contains(target.standardizedFileURL.path))
        #expect(!indexed.contains(link.standardizedFileURL.path))
        #expect(!indexed.contains(danglingLink.standardizedFileURL.path))
        let audit = try await store.auditEvents(limit: 20)
        #expect(!audit.contains { ($0.detail ?? "").contains("symbolic") })
        await indexer.stop()
    }

    @Test func testUnreadableSubdirectoryDoesNotAbortScan() async throws {
        let fixture = try makeFixture()
        let locked = fixture.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let good = fixture.root.appendingPathComponent("good.tmp")
        try Data("g".utf8).write(to: good)
        try Data("x".utf8).write(to: locked.appendingPathComponent("hidden.tmp"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        try await store.replaceSnapshot(PolicySnapshot(rules: [try makeRule(scope: root.path, recursive: true)], overrides: [], managedRoots: [root], globallyPaused: false))
        let scanned = TestExpectation("scan finished")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }) {
            scanned.fulfill()
        }
        try await indexer.start()
        await scanned.expectFulfilled(timeout: 5)
        let statuses = await waitForState(.watching, indexer: indexer)
        #expect(statuses.first?.state == .watching)
        let indexed = try await store.upcomingDeadlines().map(\.identity.pathHint)
        #expect(indexed.contains(good.standardizedFileURL.path))
        await indexer.stop()
    }

    @Test func testUnavailableRootReportsStatusAndKeepsAgentRunning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        try await store.replaceSnapshot(PolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: false))
        let retrySleep = TestExpectation("retry scheduled")
        let indexer = ManagedRootIndexer(
            store: store,
            resolver: { _ in throw CocoaError(.fileReadNoSuchFile) },
            sleep: { _ in retrySleep.fulfill(); try await Task.sleep(nanoseconds: 60_000_000_000) }
        )
        try await indexer.start()
        await retrySleep.expectFulfilled(timeout: 5)
        let statuses = await indexer.rootStatuses()
        #expect(statuses.map(\.state) == [.offline])
        await indexer.stop()
        #expect(await indexer.rootStatuses().isEmpty)
    }

    @Test func testRepeatedRecoveriesBackOffInsteadOfRescanningImmediately() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        try await store.replaceSnapshot(PolicySnapshot(rules: [try makeRule(scope: root.path)], overrides: [], managedRoots: [root], globallyPaused: false))
        let delays = DelayRecorder()
        let backedOff = TestExpectation("second recovery debounced")
        let scanned = TestExpectation("initial scan")
        let indexer = ManagedRootIndexer(
            store: store,
            resolver: { _ in fixture.root },
            clock: FixedInstantClock(Date(timeIntervalSince1970: 1_000)),
            onDeadlinesChanged: { scanned.fulfill() },
            sleep: { seconds in
                delays.record(seconds)
                backedOff.fulfill()
            }
        )
        try await indexer.start()
        await scanned.expectFulfilled(timeout: 5)

        let event = ManagedRootEvent(paths: [], flags: [], eventIDs: [10], requiresRecovery: true)
        try await indexer.processChanges(event, for: root.id)
        #expect(delays.values.isEmpty)
        try await indexer.processChanges(event, for: root.id)
        await backedOff.expectFulfilled(timeout: 5)
        #expect(delays.values.first == 2)
        await indexer.stop()
    }

    @Test func testOverrideReconcileRebuildsOnlyRequestedItem() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("item.tmp")
        try Data("i".utf8).write(to: file)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        try await store.replaceSnapshot(PolicySnapshot(rules: [try makeRule(scope: root.path)], overrides: [], managedRoots: [root], globallyPaused: false))
        let scanned = TestExpectation("initial scan")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }) { scanned.fulfill() }
        try await indexer.start()
        await scanned.expectFulfilled(timeout: 5)
        let before = await indexer.diagnosticsSnapshot()

        try await store.removeDeadlines(atOrBelow: file.standardizedFileURL.path)
        #expect(try await store.upcomingDeadlines().isEmpty)
        try await indexer.reconcileOverrides(paths: [file.path, file.path])
        #expect(try await store.upcomingDeadlines().map(\.identity.pathHint) == [file.standardizedFileURL.path])
        let after = await indexer.diagnosticsSnapshot()
        #expect(after.fullTreeScans == before.fullTreeScans)
        try await indexer.reconcileOverrides(paths: ["/not/inside/any/managed/root.tmp"])
        await indexer.stop()
    }

    @Test func testEventStreamStopIsIdempotentAndSilencesCallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try ManagedRootEventStream(rootPath: root.path, latency: 0.05) { _ in }
        stream.stop()
        stream.stop()
    }

    private func waitForState(_ state: AgentRootState, indexer: ManagedRootIndexer) async -> [AgentRootStatus] {
        var statuses = await indexer.rootStatuses()
        var attempts = 0
        while statuses.first?.state != state, attempts < 200 {
            await Task.yield()
            statuses = await indexer.rootStatuses()
            attempts += 1
        }
        return statuses
    }

    private func makeFixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Resilience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("state.sqlite3"))
    }

    private func makeRoot(_ url: URL) throws -> ManagedRoot {
        let path = url.standardizedFileURL.path
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try ManagedRoot(displayName: url.lastPathComponent, path: path, bookmarkData: bookmark)
    }

    private func makeRule(scope: String, recursive: Bool = false) throws -> LifetimeRule {
        try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: scope, recursive: recursive),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: .preview
        )
    }
}

private struct FixedInstantClock: SafetyClock {
    let instant: Date
    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { instant }
}

private final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { recorded } }
    func record(_ value: TimeInterval) { lock.withLock { recorded.append(value) } }
}
