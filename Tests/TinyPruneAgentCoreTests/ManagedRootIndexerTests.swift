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
        await observed.expectFulfilled(timeout: 30)
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
        await initialIndexed.expectFulfilled(timeout: 30)
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
        await indexed.expectFulfilled(timeout: 30)

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
        await indexed.expectFulfilled(timeout: 30)
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
        await indexed.expectFulfilled(timeout: 30)
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
        await recovered.expectFulfilled(timeout: 30)

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
        await indexed.expectFulfilled(timeout: 30)

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
        await indexed.expectFulfilled(timeout: 30)

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
        await initialScan.expectFulfilled(timeout: 30)

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

    @Test func testDirectoryRenamePreservesDescendantObservationsAcrossRestart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldDirectory = fixture.root.appendingPathComponent("before", isDirectory: true)
        let newDirectory = fixture.root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let file = oldDirectory.appendingPathComponent("idle.tmp")
        try Data("metadata".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: file.path)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview, basis: .observedActivity, recursive: true)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock)
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let before = try #require(try await store.nextDeadline())
        try FileManager.default.moveItem(at: oldDirectory, to: newDirectory)
        clock.set(Date(timeIntervalSince1970: 2_000))
        try await indexer.processChanges(ManagedRootEvent(
            paths: [oldDirectory.path, newDirectory.path],
            flags: [UInt32(kFSEventStreamEventFlagItemRemoved), UInt32(kFSEventStreamEventFlagItemRenamed)],
            eventIDs: [1, 2]), for: root.id)
        let renamedFile = newDirectory.appendingPathComponent("idle.tmp")
        let activity = try #require(try await store.observedActivity(for: before.identity))
        #expect(activity.identity.pathHint == renamedFile.path)
        #expect(activity.firstObservedAt == Date(timeIntervalSince1970: 1_000))
        await indexer.stop()
        let saved = try #require(try await store.nextDeadline())
        clock.set(Date(timeIntervalSince1970: 4_000))
        let restarted = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock)
        try await restarted.start()
        try await waitForWatching(restarted, rootID: root.id)
        let restored = try #require(try await store.nextDeadline())
        let restoredActivity = try #require(try await store.observedActivity(for: before.identity))
        #expect(restored.identity == before.identity)
        #expect(restored.scheduledAt == saved.scheduledAt)
        #expect(restoredActivity.firstObservedAt == activity.firstObservedAt)
        #expect(restoredActivity.lastObservedAt == activity.lastObservedAt)
        await restarted.stop()
    }

    @Test func testHistoricalReplayDoesNotInventObservedOrProjectActivity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = fixture.root.appendingPathComponent("sample", isDirectory: true)
        let generated = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let marker = project.appendingPathComponent("package.json")
        let source = project.appendingPathComponent("source.tmp")
        try Data("{}".utf8).write(to: marker)
        try Data("source".utf8).write(to: source)
        for url in [marker, source] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let observed = try makeRule(scope: root.path, state: .preview, basis: .observedActivity, recursive: true)
        let projectRule = try makeRule(scope: root.path, state: .preview, basis: .projectActivity,
                                      itemKind: .directory, exactNames: ["node_modules"], globPatterns: [], recursive: true)
        try await store.replaceSnapshot(PolicySnapshot(rules: [observed, projectRule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock)
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let before = try await store.upcomingDeadlines()
        let projectBefore = try await store.projectActivity(for: generated.path)
        clock.set(Date(timeIntervalSince1970: 4_000))
        try await indexer.processEvent(ManagedRootEvent(paths: [source.path, marker.path],
            flags: [UInt32(kFSEventStreamEventFlagItemModified), UInt32(kFSEventStreamEventFlagItemModified)],
            eventIDs: [10, 11]), for: root.id, replayThrough: 20)
        #expect(try await store.upcomingDeadlines() == before)
        #expect(try await store.projectActivity(for: generated.path) == projectBefore)
        try await indexer.processChanges(ManagedRootEvent(paths: [source.path],
            flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [12]), for: root.id)
        let live = try await store.upcomingDeadlines()
        #expect(live.first(where: { $0.identity.pathHint == source.path })?.explanation.basisDate == clock.now())
        #expect(try await store.projectActivity(for: generated.path) == clock.now())
        await indexer.stop()
    }

    @Test(arguments: [false, true])
    func testWakeReplayRefreshesProjectActivityBeforeReadiness(deletedSource: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = fixture.root.appendingPathComponent("sample", isDirectory: true)
        let generated = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let marker = project.appendingPathComponent("package.json")
        let source = project.appendingPathComponent("source.swift")
        try Data("{}".utf8).write(to: marker)
        try Data("source".utf8).write(to: source)
        for url in [marker, source, generated, project] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        // A truly global template must track projects outside its nominal scope.
        let rule = try makeRule(scope: "/Templates", state: .preview, basis: .projectActivity,
                                itemKind: .directory, exactNames: ["node_modules"], globPatterns: [],
                                recursive: true, matchMode: .template)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock,
                                        eventStreamFactory: { _, _, _ in nil })
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        #expect(try await store.projectActivity(for: generated.path) == Date(timeIntervalSince1970: 100))
        let due = try #require(try await store.upcomingDeadlines().first)
        #expect(due.scheduledAt < clock.now())
        try await store.saveEventCursor(for: root.id, eventID: 1)
        let activityDate = Date(timeIntervalSince1970: 3_980)
        if deletedSource {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.setAttributes([.modificationDate: activityDate], ofItemAtPath: project.path)
        } else {
            try Data("edited".utf8).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: activityDate], ofItemAtPath: source.path)
        }
        clock.set(Date(timeIntervalSince1970: 4_000))
        try await indexer.resumeAfterWake()
        #expect(!(await indexer.canExecuteDeadline(at: generated.path)))
        try await indexer.processEvent(ManagedRootEvent(paths: [source.path],
            flags: [UInt32(deletedSource ? kFSEventStreamEventFlagItemRemoved : kFSEventStreamEventFlagItemModified)],
            eventIDs: [2]), for: root.id, replayThrough: 10)
        #expect(!(await indexer.canExecuteDeadline(at: generated.path)))
        #expect(try await store.projectActivity(for: generated.path) == activityDate)
        let refreshed = try #require(try await store.upcomingDeadlines().first)
        #expect(refreshed.explanation.basisDate == activityDate)
        #expect(refreshed.scheduledAt > clock.now())
        try await indexer.processEvent(ManagedRootEvent(paths: [root.path],
            flags: [UInt32(kFSEventStreamEventFlagHistoryDone)], eventIDs: [10]),
            for: root.id, replayThrough: 10)
        #expect(await indexer.canExecuteDeadline(at: generated.path))
        #expect(try await store.projectActivity(for: generated.path) == activityDate)
        await indexer.stop()
    }

    @Test func testEmptyWakeReplayBecomesReadyOnlyAtHistoryDoneWithoutRootActivity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("idle.tmp")
        try Data("idle".utf8).write(to: file)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview, basis: .observedActivity)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock,
                                        eventStreamFactory: { _, _, _ in nil })
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let before = try await store.upcomingDeadlines()
        let indexedEntries = await indexer.diagnosticsSnapshot().indexedEntries
        try await store.saveEventCursor(for: root.id, eventID: 1)
        clock.set(Date(timeIntervalSince1970: 4_000))
        try await indexer.resumeAfterWake()
        #expect(!(await indexer.canExecuteDeadline(at: file.path)))
        try await indexer.processEvent(ManagedRootEvent(paths: [], flags: [], eventIDs: []),
                                       for: root.id, replayThrough: 10)
        #expect(!(await indexer.canExecuteDeadline(at: file.path)))
        try await indexer.processEvent(ManagedRootEvent(paths: [root.path],
            flags: [UInt32(kFSEventStreamEventFlagHistoryDone)], eventIDs: [10]),
            for: root.id, replayThrough: 10)
        #expect(await indexer.canExecuteDeadline(at: file.path))
        #expect(try await store.upcomingDeadlines() == before)
        #expect(await indexer.diagnosticsSnapshot().indexedEntries == indexedEntries)
        await indexer.stop()
    }

    @Test func testGlobalTemplateChangeInvalidatesUnrelatedManagedRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.root.appendingPathComponent("idle.tmp")
        try Data("idle".utf8).write(to: file)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: "/Templates", state: .preview, matchMode: .template)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root },
                                        eventStreamFactory: { _, _, _ in nil })
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let scans = await indexer.diagnosticsSnapshot().fullTreeScans
        let changed = try makeRule(scope: "/Templates", state: .preview, basis: .created, matchMode: .template)
        try await store.replaceSnapshot(PolicySnapshot(rules: [changed], overrides: [], managedRoots: [root], globallyPaused: false))
        try await indexer.reconfigure()
        try await waitForWatching(indexer, rootID: root.id)
        #expect(await indexer.diagnosticsSnapshot().fullTreeScans == scans + 1)
        let deadline = try #require(try await store.upcomingDeadlines().first)
        #expect(deadline.explanation.matchedRuleID == changed.id)
        await indexer.stop()
    }

    @Test func testOfflineReconfigurationRetainsPublishedDeadlines() async throws {
        let fixture = try makeFixture()
        let offline = fixture.root.appendingPathExtension("offline")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: offline)
        }
        let file = fixture.root.appendingPathComponent("idle.tmp")
        try Data("retain".utf8).write(to: file)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root })
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let before = try await store.upcomingDeadlines()
        #expect(!before.isEmpty)
        try FileManager.default.moveItem(at: fixture.root, to: offline)
        try await indexer.reconcileManagedRoots(at: [root.path])
        #expect(try await store.upcomingDeadlines() == before)
        #expect(!(await indexer.canExecuteDeadline(at: file.path)))
        await indexer.stop()
    }

    @Test func testMarkerEditsAreIncrementalAndGeneratedChildrenKeepMatchingOtherRules() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = fixture.root.appendingPathComponent("sample", isDirectory: true)
        let generated = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let marker = project.appendingPathComponent("package.json")
        let child = generated.appendingPathComponent("cache.tmp")
        try Data("{}".utf8).write(to: marker)
        try Data("generated".utf8).write(to: child)
        for url in [marker, child] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        }
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let childRule = try makeRule(scope: root.path, state: .preview, recursive: true)
        let projectRule = try makeRule(scope: root.path, state: .preview, basis: .projectActivity,
                                      itemKind: .directory, exactNames: ["node_modules"], globPatterns: [], recursive: true)
        try await store.replaceSnapshot(PolicySnapshot(rules: [childRule, projectRule], overrides: [], managedRoots: [root], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: clock)
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        #expect(try await store.upcomingDeadlines().contains(where: { $0.identity.pathHint == child.path }))
        let diagnostics = await indexer.diagnosticsSnapshot()
        clock.set(Date(timeIntervalSince1970: 2_000))
        try await indexer.processChanges(ManagedRootEvent(paths: [marker.path],
            flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [1]), for: root.id)
        let afterDiagnostics = await indexer.diagnosticsSnapshot()
        #expect(afterDiagnostics.indexedEntries == diagnostics.indexedEntries)
        #expect(afterDiagnostics.fullTreeScans == diagnostics.fullTreeScans)
        let afterMarker = try await store.upcomingDeadlines()
        #expect(afterMarker.first(where: { $0.identity.pathHint == generated.path })?.explanation.basisDate == clock.now())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: child.path)
        try await indexer.processChanges(ManagedRootEvent(paths: [child.path],
            flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [2]), for: root.id)
        let afterChild = try await store.upcomingDeadlines()
        #expect(afterChild.first(where: { $0.identity.pathHint == child.path })?.explanation.basisDate == Date(timeIntervalSince1970: 300))
        #expect(afterChild.first(where: { $0.identity.pathHint == generated.path })?.explanation.basisDate == clock.now())
        await indexer.stop()
    }

    @Test func overlappingRootsRetainNestedIdentityDatesThroughRecoveryAndRemoval() async throws {
        let fixture = try makeFixture()
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Overlap-\(UUID()).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
        }
        let child = fixture.root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let file = child.appendingPathComponent("retained.tmp")
        try Data("retained identity".utf8).write(to: file)
        let parentRoot = try makeRoot(fixture.root)
        let childRoot = try makeRoot(child)
        let rule = try makeRule(scope: child.path, state: .preview, basis: .firstObserved, recursive: true)
        let store = try SQLiteSafetyStore(databaseURL: database)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [parentRoot, childRoot], globallyPaused: false))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let indexer = ManagedRootIndexer(store: store, resolver: { root in URL(fileURLWithPath: root.path) }, clock: clock)
        try await indexer.start()
        try await waitForWatching(indexer, rootID: parentRoot.id)
        try await waitForWatching(indexer, rootID: childRoot.id)
        let before = try #require(try await store.nextDeadline())
        #expect(before.scheduledAt == Date(timeIntervalSince1970: 1_060))
        async let parentRecovery: Void = indexer.processChanges(ManagedRootEvent(paths: [], flags: [], eventIDs: [50], requiresRecovery: true), for: parentRoot.id)
        async let childRecovery: Void = indexer.processChanges(ManagedRootEvent(paths: [], flags: [], eventIDs: [51], requiresRecovery: true), for: childRoot.id)
        _ = try await (parentRecovery, childRecovery)
        #expect(try await store.indexedDeadlineCount() == 1)
        #expect(try await store.nextDeadline()?.scheduledAt == before.scheduledAt)
        clock.set(Date(timeIntervalSince1970: 2_000))
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [childRoot], globallyPaused: false))
        try await indexer.reconfigure()
        try await waitForWatching(indexer, rootID: childRoot.id)
        let after = try #require(try await store.nextDeadline())
        #expect(after.identity == before.identity)
        #expect(after.scheduledAt == before.scheduledAt)
        #expect(try await store.observedActivity(for: after.identity)?.firstObservedAt == Date(timeIntervalSince1970: 1_000))
        await indexer.stop()
    }

    @Test func gitBookkeepingDoesNotAdvanceProjectExpiryAcrossRestart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = fixture.root.appendingPathComponent("project")
        let git = project.appendingPathComponent(".git")
        let generated = project.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("source.swift")
        try Data("source".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([
            .creationDate: Date(timeIntervalSince1970: 100),
            .modificationDate: Date(timeIntervalSince1970: 9_000)
        ], ofItemAtPath: git.path)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try LifetimeRule(
            name: "Project cleanup", scope: RuleScope(path: root.path, recursive: true),
            matcher: ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
            expiryBasis: .projectActivity, lifetime: RuleDuration(seconds: 60),
            action: .trashItem, state: .preview
        )
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root }, clock: FixedClock(Date(timeIntervalSince1970: 1_000)))
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let before = try #require(try await store.nextDeadline())
        #expect(before.scheduledAt == Date(timeIntervalSince1970: 260))
        await indexer.stop()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 19_000)], ofItemAtPath: git.path)
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        #expect(try await store.nextDeadline()?.scheduledAt == before.scheduledAt)
        #expect(try await store.projectActivity(for: generated.path) == Date(timeIntervalSince1970: 200))
        await indexer.stop()
    }

    @Test func testUnreadableRecoveryRetainsUnavailableSchedulesAndIndexesReadableItems() async throws {
        let fixture = try makeFixture()
        let directory = fixture.root.appendingPathComponent("private", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("idle.tmp")
        try Data("retain".utf8).write(to: file)
        let store = try SQLiteSafetyStore(databaseURL: fixture.databaseURL)
        let root = try makeRoot(fixture.root)
        let rule = try makeRule(scope: root.path, state: .preview, recursive: true)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store, resolver: { _ in fixture.root })
        try await indexer.start()
        try await waitForWatching(indexer, rootID: root.id)
        let before = try await store.upcomingDeadlines()
        #expect(before.contains(where: { $0.identity.pathHint == file.path }))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        let readable = fixture.root.appendingPathComponent("readable.tmp")
        try Data("accessible".utf8).write(to: readable)
        try await indexer.processChanges(ManagedRootEvent(paths: [], flags: [], eventIDs: [50], requiresRecovery: true), for: root.id)
        let after = try await store.upcomingDeadlines()
        #expect(after.filter { $0.identity == before.first?.identity } == before)
        #expect(Set(after.map(\.identity.pathHint)) == Set([file.path, readable.path]))
        await indexer.stop()
    }

    @Test func testPolicyReconfigurationLeavesUnchangedRootsAndPauseSettingsUnscanned() async throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: firstFixture.root)
            try? FileManager.default.removeItem(at: secondFixture.root)
        }
        let firstFile = firstFixture.root.appendingPathComponent("one.tmp")
        let secondFile = secondFixture.root.appendingPathComponent("two.tmp")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)
        let store = try SQLiteSafetyStore(databaseURL: firstFixture.databaseURL)
        let firstRoot = try makeRoot(firstFixture.root)
        let secondRoot = try makeRoot(secondFixture.root)
        let firstRule = try makeRule(scope: firstRoot.path, state: .preview)
        let secondRule = try makeRule(scope: secondRoot.path, state: .preview)
        let roots = [firstRoot, secondRoot]
        try await store.replaceSnapshot(PolicySnapshot(rules: [firstRule, secondRule], overrides: [], managedRoots: roots, globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store, resolver: { root in URL(fileURLWithPath: root.path) })
        try await indexer.start()
        try await waitForWatching(indexer, rootID: firstRoot.id)
        try await waitForWatching(indexer, rootID: secondRoot.id)
        let original = await indexer.diagnosticsSnapshot()
        try await store.replaceSnapshot(PolicySnapshot(rules: [firstRule, secondRule], overrides: [], managedRoots: roots,
            globallyPaused: true, settings: AgentSettings(activityRetentionDays: 30)))
        try await indexer.reconfigure()
        #expect(await indexer.diagnosticsSnapshot().fullTreeScans == original.fullTreeScans)
        let before = try await store.upcomingDeadlines()
        let secondDeadline = try #require(before.first(where: { $0.identity.pathHint == secondFile.path }))
        let changedFirstRule = try makeRule(scope: firstRoot.path, state: .preview, basis: .created)
        try await store.replaceSnapshot(PolicySnapshot(rules: [changedFirstRule, secondRule], overrides: [], managedRoots: roots,
            globallyPaused: true, settings: AgentSettings(activityRetentionDays: 30)))
        try await indexer.reconfigure()
        try await waitForWatching(indexer, rootID: firstRoot.id)
        #expect(await indexer.diagnosticsSnapshot().fullTreeScans == original.fullTreeScans + 1)
        #expect(await indexer.canExecuteDeadline(at: secondFile.path))
        let after = try await store.upcomingDeadlines()
        #expect(after.first(where: { $0.identity.pathHint == secondFile.path }) == secondDeadline)
        await indexer.stop()
    }

    private func waitForWatching(_ indexer: ManagedRootIndexer, rootID: UUID) async throws {
        for _ in 0..<500 {
            if await indexer.rootStatuses().contains(where: { $0.rootID == rootID && $0.state == .watching }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ManagedRootIndexerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Root never completed indexing"])
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
        recursive: Bool = false,
        matchMode: RuleMatchMode = .scoped
    ) throws -> LifetimeRule {
        try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: scope, recursive: recursive),
            matcher: ItemMatcher(itemKind: itemKind, exactNames: exactNames, globPatterns: globPatterns),
            expiryBasis: basis,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: state,
            matchMode: matchMode
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
