import CoreServices
import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence


@Suite struct ManagedRootIndexerTests {
    @Test func testFSEventStreamDeliversCreatedFilePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-FSEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("created.tmp")
        let observed = TestExpectation("FSEvents reports a file created under the managed root")
        let stream = try ManagedRootEventStream(rootPath: root.path, latency: 0.05) { event in
            if event.paths.contains(where: { $0.hasSuffix("/created.tmp") }) { observed.fulfill() }
        }
        defer { stream.stop() }

        try Data("event fixture".utf8).write(to: file)
        await observed.expectFulfilled(timeout: 5)
    }
    @Test func testInitialIndexAndPathEventsUpdateOnlyMatchingDeadlines() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.root.appendingPathComponent("old.tmp")
        try Data("metadata only".utf8).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: original.path)

        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let initialIndexed = TestExpectation("initial root scan persisted candidate deadlines")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }) {
            Task {
                if let deadlines = try? await store.upcomingDeadlines(), !deadlines.isEmpty {
                    initialIndexed.fulfill()
                }
            }
        }
        defer { Task { await indexer.stop() } }

        try await indexer.start()
        await initialIndexed.expectFulfilled(timeout: 5)
        let initial = try await store.upcomingDeadlines()
        #expect(initial.map(\.identity.pathHint) == [original.standardizedFileURL.path])
        #expect(initial.first?.explanation.disposition == .preview)

        let created = fixture.root.appendingPathComponent("new.tmp")
        try Data("new metadata".utf8).write(to: created)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: created.path)
        try await indexer.processChanges(
            ManagedRootEvent(paths: [created.path], flags: [UInt32(kFSEventStreamEventFlagItemCreated)], eventIDs: [1]),
            for: root.id
        )
        let afterCreate = try await store.upcomingDeadlines()
        #expect(Set(afterCreate.map(\.identity.pathHint)) == Set([original.standardizedFileURL.path, created.standardizedFileURL.path]))

        try FileManager.default.removeItem(at: original)
        try await indexer.processChanges(
            ManagedRootEvent(paths: [original.path], flags: [UInt32(kFSEventStreamEventFlagItemRemoved)], eventIDs: [2]),
            for: root.id
        )
        let afterDelete = try await store.upcomingDeadlines()
        #expect(afterDelete.map(\.identity.pathHint) == [created.standardizedFileURL.path])
        await indexer.stop()
    }

    @Test func testObservedActivityResetsExpiryAfterFilesystemEvent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("idle.tmp")
        try Data("metadata only".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: file.path)

        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview, basis: .observedActivity)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexed = TestExpectation("initial observed-activity deadline persisted")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock) {
            Task {
                if let deadlines = try? await store.upcomingDeadlines(), !deadlines.isEmpty {
                    indexed.fulfill()
                }
            }
        }
        try await indexer.start()
        await indexed.expectFulfilled(timeout: 5)

        let initialDeadlines = try await store.upcomingDeadlines()
        let initial = try #require(initialDeadlines.first)
        #expect(initial.explanation.basisDate == Date(timeIntervalSince1970: 1_000))
        clock.set(Date(timeIntervalSince1970: 2_000))
        try await indexer.processChanges(
            ManagedRootEvent(paths: [file.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [3]),
            for: root.id
        )

        let updatedDeadlines = try await store.upcomingDeadlines()
        let updated = try #require(updatedDeadlines.first)
        #expect(updated.explanation.basisDate == Date(timeIntervalSince1970: 2_000))
        #expect(updated.scheduledAt == Date(timeIntervalSince1970: 2_060))
        let storedActivity = try await store.observedActivity(for: updated.identity)
        let activity = try #require(storedActivity)
        #expect(activity.firstObservedAt == Date(timeIntervalSince1970: 1_000))
        #expect(activity.lastObservedAt == Date(timeIntervalSince1970: 2_000))
        await indexer.stop()
    }

    @Test func testFileRenameReconcilesStableIdentityAndPersistsEventCursor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldURL = fixture.root.appendingPathComponent("old.tmp")
        let newURL = fixture.root.appendingPathComponent("renamed.tmp")
        try Data("rename".utf8).write(to: oldURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: oldURL.path)

        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview, basis: .observedActivity)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexed = TestExpectation("original identity indexed")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock) {
            Task {
                if let deadlines = try? await store.upcomingDeadlines(),
                   deadlines.contains(where: { $0.identity.pathHint == oldURL.path }) {
                    indexed.fulfill()
                }
            }
        }
        try await indexer.start()
        await indexed.expectFulfilled(timeout: 5)
        let before = try await store.nextDeadline()
        let original = try #require(before)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        clock.set(Date(timeIntervalSince1970: 2_000))

        try await indexer.processChanges(
            ManagedRootEvent(
                paths: [newURL.path, oldURL.path],
                flags: [UInt32(kFSEventStreamEventFlagItemRenamed), UInt32(kFSEventStreamEventFlagItemRemoved)],
                eventIDs: [2, 3]
            ),
            for: root.id
        )
        let after = try await store.nextDeadline()
        let renamed = try #require(after)
        let activity = try await store.observedActivity(for: renamed.identity)
        let cursor = try await store.eventCursor(for: root.id)
        #expect(renamed.identity == original.identity)
        #expect(renamed.identity.pathHint == newURL.path)
        #expect(renamed.explanation.basisDate == Date(timeIntervalSince1970: 2_000))
        #expect(activity?.firstObservedAt == Date(timeIntervalSince1970: 1_000))
        #expect(activity?.lastObservedAt == Date(timeIntervalSince1970: 2_000))
        #expect(cursor ?? 0 >= 3)
        let deadlines = try await store.upcomingDeadlines()
        #expect(deadlines.count == 1)
        await indexer.stop()
    }

    @Test func testRestartRebuildPreservesPersistedKeepProtection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("protected.tmp")
        try Data("preserve".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)

        let firstStore = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .active)
        try await firstStore.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexed = TestExpectation("candidate deadline persisted before restart")
        let firstIndexer = ManagedRootIndexer(store: firstStore, resolver: { _ in fixture.root }) {
            Task {
                if let deadlines = try? await firstStore.upcomingDeadlines(),
                   deadlines.contains(where: { $0.identity.pathHint == file.path }) {
                    indexed.fulfill()
                }
            }
        }
        try await firstIndexer.start()
        await indexed.expectFulfilled(timeout: 5)
        let inspectedCandidate = try await firstIndexer.inspectManagedPath(file.path)
        let candidate = try #require(inspectedCandidate)
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))
        try await firstStore.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [keep], managedRoots: [root], globallyPaused: false))
        await firstIndexer.stop()

        let reopenedStore = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let recovered = TestExpectation("restart completed root reconciliation")
        let callbackSignal = ScanCompletionSignal(requiredCallbacks: 2, expectation: recovered)
        let restartedIndexer = ManagedRootIndexer(store: reopenedStore, resolver: { _ in fixture.root }) {
            callbackSignal.record()
        }
        try await restartedIndexer.start()
        await recovered.expectFulfilled(timeout: 5)

        let snapshot = try await reopenedStore.loadSnapshot()
        let deadlines = try await reopenedStore.upcomingDeadlines()
        #expect(snapshot.overrides == [keep])
        #expect(deadlines.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await restartedIndexer.stop()
    }

    @Test func testProjectActivityUsesMeaningfulFilesAndRefreshesProjectDeadlines() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = fixture.root.appendingPathComponent("sample", isDirectory: true)
        let sourceDirectory = project.appendingPathComponent("Sources", isDirectory: true)
        let generatedDirectory = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let manifest = project.appendingPathComponent("package.json")
        let source = sourceDirectory.appendingPathComponent("main.swift")
        let generated = generatedDirectory.appendingPathComponent("bundle.js")
        try Data("{}".utf8).write(to: manifest)
        try Data("print(1)".utf8).write(to: source)
        try Data("generated".utf8).write(to: generated)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 90)], ofItemAtPath: manifest.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 500)], ofItemAtPath: generated.path)

        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(
            scope: root.path,
            state: .preview,
            basis: .projectActivity,
            itemKind: .directory,
            exactNames: ["node_modules"],
            globPatterns: [],
            recursive: true
        )
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexed = TestExpectation("project-activity deadline persisted")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock) {
            Task {
                if let deadlines = try? await store.upcomingDeadlines(),
                   deadlines.contains(where: { $0.identity.pathHint == generatedDirectory.path }) {
                    indexed.fulfill()
                }
            }
        }
        try await indexer.start()
        await indexed.expectFulfilled(timeout: 5)

        let initialDeadline = try await store.nextDeadline()
        let initial = try #require(initialDeadline)
        let initialProjectActivity = try await store.projectActivity(for: generatedDirectory.path)
        #expect(initial.explanation.basisDate == Date(timeIntervalSince1970: 100))
        #expect(initialProjectActivity == Date(timeIntervalSince1970: 100))

        clock.set(Date(timeIntervalSince1970: 2_000))
        try await indexer.processChanges(
            ManagedRootEvent(paths: [generated.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [4]),
            for: root.id
        )
        let generatedDeadline = try await store.nextDeadline()
        let afterGeneratedNoise = try #require(generatedDeadline)
        #expect(afterGeneratedNoise.scheduledAt == Date(timeIntervalSince1970: 160))

        clock.set(Date(timeIntervalSince1970: 3_000))
        try await indexer.processChanges(
            ManagedRootEvent(paths: [source.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [5]),
            for: root.id
        )
        let sourceDeadline = try await store.nextDeadline()
        let afterSourceActivity = try #require(sourceDeadline)
        #expect(afterSourceActivity.explanation.basisDate == Date(timeIntervalSince1970: 3_000))
        #expect(afterSourceActivity.scheduledAt == Date(timeIntervalSince1970: 3_060))
        await indexer.stop()
    }

    @Test func testDueActiveDeadlineRunsFinalTrashPreflight() async throws {
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
        let indexed = TestExpectation("active candidate persisted before due scheduling")
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }) {
            Task {
                if let deadlines = try? await store.upcomingDeadlines(),
                   deadlines.contains(where: { $0.identity.pathHint == candidateURL.path }) {
                    indexed.fulfill()
                }
            }
        }
        try await indexer.start()
        await indexed.expectFulfilled(timeout: 5)

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

        #expect(!(FileManager.default.fileExists(atPath: candidateURL.path)))
        let events = try await store.auditEvents()
        let move = try #require(events.first(where: { $0.kind == .movedToTrash }))
        trashedPath = move.detail
        #expect(trashedPath != nil)
        let remaining = try await store.upcomingDeadlines()
        #expect(remaining.isEmpty)
    }

    @Test func testEventOverflowRecoveryRebuildsDeadlinesAndPersistsCursor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .active)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let initialScan = TestExpectation("initial scan completed")
        let callbackSignal = ScanCompletionSignal(requiredCallbacks: 2, expectation: initialScan)
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }) {
            callbackSignal.record()
        }
        try await indexer.start()
        await initialScan.expectFulfilled(timeout: 5)

        let missedFile = fixture.root.appendingPathComponent("missed.tmp")
        try Data("recovery".utf8).write(to: missedFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: missedFile.path)
        try await indexer.processChanges(
            ManagedRootEvent(paths: [], flags: [], eventIDs: [900], requiresRecovery: true),
            for: root.id
        )

        let deadlines = try await store.upcomingDeadlines()
        let eventCursor = try await store.eventCursor(for: root.id)
        let diagnostics = await indexer.diagnosticsSnapshot()
        #expect(deadlines.contains(where: { $0.identity.pathHint == missedFile.path }))
        #expect(eventCursor ?? 0 >= 900)
        #expect(diagnostics.recoveryCount == 1)
        await indexer.stop()
    }

    private func makeFixture() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Indexer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("state.sqlite3")
        return (root, databaseURL)
    }

    private func makeRoot(_ url: URL) throws -> ManagedRoot {
        let path = url.standardizedFileURL.path
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try ManagedRoot(displayName: url.lastPathComponent, path: path, bookmarkData: bookmark)
    }

    private func makeRule(
        scope: String,
        state: RuleState,
        basis: ExpiryBasis = .modified,
        itemKind: ItemKind = .file,
        exactNames: Set<String> = [],
        globPatterns: Set<String> = ["*.tmp"],
        recursive: Bool = false
    ) throws -> LifetimeRule {
        try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: scope, recursive: recursive),
            matcher: ItemMatcher(itemKind: itemKind, exactNames: exactNames, globPatterns: globPatterns),
            expiryBasis: basis,
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

private final class MutableClock: SafetyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    func now() -> Date {
        lock.withLock { instant }
    }

    func set(_ instant: Date) {
        lock.withLock { self.instant = instant }
    }
}

private final class ScanCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let requiredCallbacks: Int
    private let expectation: TestExpectation
    private var callbacks = 0

    init(requiredCallbacks: Int, expectation: TestExpectation) {
        self.requiredCallbacks = requiredCallbacks
        self.expectation = expectation
    }

    func record() {
        let fulfilled = lock.withLock {
            callbacks += 1
            return callbacks == requiredCallbacks
        }
        if fulfilled { expectation.fulfill() }
    }
}
