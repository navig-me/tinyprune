import Foundation
import Testing
@testable import TinyPruneDomain
@testable import TinyPruneEngine
@testable import TinyPrunePersistence

@Suite struct SQLiteSafetyStoreTests {
    @Test func testSnapshotPersistsAndFailedReplacementRollsBack() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule(name: "Original")
        let keep = ItemPolicyOverride(path: "/Developer/safe", policy: .keep(protectDescendants: true))
        let root = try ManagedRoot(displayName: "Developer", path: "/Developer", bookmarkData: Data([1, 2, 3]))
        let snapshot = PolicySnapshot(rules: [rule], overrides: [keep], managedRoots: [root], globallyPaused: true)
        try await harness.store.replaceSnapshot(snapshot)

        let loaded = try await harness.store.loadSnapshot()
        #expect(loaded.rules == [rule])
        #expect(loaded.overrides == [keep])
        #expect(loaded.managedRoots == [root])
        #expect(loaded.globallyPaused)

        let duplicate = try makeRule(id: rule.id, name: "Duplicate")
        do {
            try await harness.store.replaceSnapshot(PolicySnapshot(rules: [rule, duplicate], overrides: [], globallyPaused: false))
            Issue.record("Duplicate rule IDs must fail the transaction")
        } catch {}

        let afterRollback = try await harness.store.loadSnapshot()
        #expect(afterRollback.rules == [rule])
        #expect(afterRollback.overrides == [keep])
        #expect(afterRollback.managedRoots == [root])
        #expect(afterRollback.globallyPaused)
        let events = try await harness.store.auditEvents()
        #expect(events.count == 1)
        #expect(events.first?.kind == .policyReplaced)
    }

    @Test func testAuditEventsAreDurableAndOrderedNewestFirst() async throws {
        let harness = try makeStore()
        let identity = makeIdentity()
        let older = TrashAuditEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, occurredAt: Date(timeIntervalSince1970: 10), kind: .previewSkipped, identity: identity, ruleID: nil)
        let newer = TrashAuditEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!, occurredAt: Date(timeIntervalSince1970: 20), kind: .movedToTrash, identity: identity, ruleID: UUID(), detail: "/.Trash/file")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await harness.store.append(older)
        try await harness.store.append(newer)
        let events = try await harness.store.auditEvents()

        #expect(events == [newer, older])
        do {
            try await harness.store.append(older)
            Issue.record("Duplicate audit IDs must be rejected")
        } catch {}
    }

    @Test func testDeadlineIndexReturnsEarliestAndReplacesByStableIdentity() async throws {
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
        #expect(next?.identity.resourceIdentifier == Data([2]))
        #expect(next?.scheduledAt == Date(timeIntervalSince1970: 22))
        try await harness.store.removeDeadline(for: secondIdentity)
        let nextAfterRemoval = try await harness.store.nextDeadline()
        #expect(nextAfterRemoval?.scheduledAt == Date(timeIntervalSince1970: 33))
    }

    @Test func testDeadlinePageSeparatesRootAndCapsPagesAt256Rows() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule(name: "Paged deadlines")
        for index in 0..<257 {
            let path = "/Developer/project/item-\(index).zip"
            let identity = makeIdentity(resource: Data(String(index).utf8), path: path)
            let timestamp = Date(timeIntervalSince1970: Double(index + 1))
            let candidate = RuleCandidate(
                identity: identity,
                name: URL(fileURLWithPath: path).lastPathComponent,
                kind: .file,
                timestamps: CandidateTimestamps(modified: timestamp)
            )
            let explanation = CandidateExplanation(
                candidate: candidate,
                rule: rule,
                basisDate: timestamp,
                eligibleAt: timestamp.addingTimeInterval(60),
                scheduledAt: timestamp.addingTimeInterval(60),
                disposition: .active
            )
            try await harness.store.saveDeadline(PersistedDeadline(
                identity: identity,
                scheduledAt: explanation.scheduledAt,
                explanation: explanation
            ))
        }

        let firstPage = try await harness.store.deadlinePage(atOrBelow: "/Developer/project", limit: 300)
        let firstCursor = try #require(firstPage.nextCursor)
        let secondPage = try await harness.store.deadlinePage(
            atOrBelow: "/Developer/project",
            afterIdentityKey: firstCursor,
            limit: 300
        )
        #expect(firstPage.deadlines.count == 256)
        #expect(secondPage.deadlines.count == 1)
        #expect(secondPage.nextCursor == nil)
        #expect(firstPage.deadlines.last?.identity != secondPage.deadlines.first?.identity)
    }

    @Test func testRemovingPathClearsOnlyThatSubtree() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rule = try makeRule(name: "Downloads archives")
        let paths = [
            "/Developer/cache/build/output.zip",
            "/Developer/cache/old.zip",
            "/Developer/cache-old/keep.zip",
        ]
        for (index, path) in paths.enumerated() {
            let identity = makeIdentity(resource: Data([UInt8(index + 1)]), path: path)
            let observedAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
            let candidate = RuleCandidate(identity: identity, name: URL(fileURLWithPath: path).lastPathComponent, kind: .file, timestamps: CandidateTimestamps(modified: observedAt))
            let deadline = observedAt.addingTimeInterval(60)
            let explanation = CandidateExplanation(candidate: candidate, rule: rule, basisDate: observedAt, eligibleAt: deadline, scheduledAt: deadline, disposition: .preview)
            try await harness.store.saveDeadline(PersistedDeadline(identity: identity, scheduledAt: deadline, explanation: explanation))
        }

        try await harness.store.removeDeadlines(atOrBelow: "/Developer/cache")

        let remaining = try await harness.store.upcomingDeadlines()
        #expect(remaining.count == 1)
        #expect(remaining.first?.identity.pathHint == "/Developer/cache-old/keep.zip")
    }

    @Test func testObservedActivityPersistsAcrossInitialScansAndRemovesBySubtree() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let identity = makeIdentity(resource: Data([7]), path: "/Developer/project/node_modules")
        let movedIdentity = makeIdentity(resource: Data([7]), path: "/Developer/archive/node_modules")
        let neighbor = makeIdentity(resource: Data([8]), path: "/Developer/project-old/node_modules")
        let initial = Date(timeIntervalSince1970: 100)
        try await harness.store.recordInitialObservations([
            PersistedObservedActivity(identity: identity, firstObservedAt: initial, lastObservedAt: initial),
            PersistedObservedActivity(identity: neighbor, firstObservedAt: initial, lastObservedAt: initial)
        ])
        try await harness.store.recordObservedActivity(identity: identity, at: Date(timeIntervalSince1970: 200))
        try await harness.store.recordInitialObservations([
            PersistedObservedActivity(identity: movedIdentity, firstObservedAt: Date(timeIntervalSince1970: 300), lastObservedAt: Date(timeIntervalSince1970: 300))
        ])

        let preserved = try await harness.store.observedActivity(for: movedIdentity)
        #expect(preserved?.firstObservedAt == initial)
        #expect(preserved?.lastObservedAt == Date(timeIntervalSince1970: 200))
        try await harness.store.reconcileObservedActivity(identity: movedIdentity, through: Date(timeIntervalSince1970: 300))
        let reconciled = try await harness.store.observedActivity(for: movedIdentity)
        #expect(reconciled?.firstObservedAt == initial)
        #expect(reconciled?.lastObservedAt == Date(timeIntervalSince1970: 300))
        try await harness.store.removeObservedActivity(atOrBelow: "/Developer/archive")
        let removed = try await harness.store.observedActivity(for: movedIdentity)
        let remainingNeighbor = try await harness.store.observedActivity(for: neighbor)
        #expect(removed == nil)
        #expect(remainingNeighbor != nil)
    }

    @Test func testEventCursorRoundTripsUnsignedFSEventIDs() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rootID = UUID()
        let eventID = UInt64.max - 3

        try await harness.store.saveEventCursor(for: rootID, eventID: eventID)

        let saved = try await harness.store.eventCursor(for: rootID)
        #expect(saved == eventID)
        try await harness.store.removeEventCursor(for: rootID)
        let removed = try await harness.store.eventCursor(for: rootID)
        #expect(removed == nil)
    }

    @Test func testProjectActivityUsesNearestProjectAndPrunesMissingProjectsOnScan() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let rootProject = makeIdentity(resource: Data([10]), path: "/Developer/project")
        let nestedProject = makeIdentity(resource: Data([11]), path: "/Developer/project/packages/nested")
        let initialScan = try await harness.store.beginProjectActivityScan()
        try await harness.store.recordProjectActivities([
            PersistedProjectActivity(identity: rootProject, lastActivityAt: Date(timeIntervalSince1970: 100)),
            PersistedProjectActivity(identity: nestedProject, lastActivityAt: Date(timeIntervalSince1970: 150))
        ], scanID: initialScan)
        try await harness.store.recordProjectObservations([
            ProjectActivityObservation(path: "/Developer/project/src/main.swift", modifiedAt: Date(timeIntervalSince1970: 200)),
            ProjectActivityObservation(path: "/Developer/project/packages/nested/main.swift", modifiedAt: Date(timeIntervalSince1970: 300))
        ], scanID: initialScan)
        try await harness.store.finishProjectActivityScan(scanID: initialScan, atOrBelow: "/Developer")

        let outerActivity = try await harness.store.projectActivity(for: "/Developer/project/src/main.swift")
        let nestedActivity = try await harness.store.projectActivity(for: "/Developer/project/packages/nested/src/main.swift")
        #expect(outerActivity == Date(timeIntervalSince1970: 200))
        #expect(nestedActivity == Date(timeIntervalSince1970: 300))

        let nestedEventRoot = try await harness.store.recordProjectActivity(
            at: "/Developer/project/packages/nested/src/main.swift",
            date: Date(timeIntervalSince1970: 400)
        )
        #expect(nestedEventRoot == nestedProject.pathHint)

        let recoveryScan = try await harness.store.beginProjectActivityScan()
        try await harness.store.recordProjectActivities([
            PersistedProjectActivity(identity: rootProject, lastActivityAt: Date(timeIntervalSince1970: 500))
        ], scanID: recoveryScan)
        try await harness.store.finishProjectActivityScan(scanID: recoveryScan, atOrBelow: "/Developer/project")
        let afterNestedRemoval = try await harness.store.recordProjectActivity(
            at: "/Developer/project/packages/nested/src/main.swift",
            date: Date(timeIntervalSince1970: 600)
        )
        #expect(afterNestedRemoval == rootProject.pathHint)
    }

    @Test func testTimedPauseLapsesAtReadTimeAndIsAuditedOnce() async throws {
        let clock = StoreTestClock(Date(timeIntervalSince1970: 1_000_000))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-SQLite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"), clock: clock)
        let end = clock.now().addingTimeInterval(600)
        try await store.setGlobalPause(true, until: end, auditEvent: TrashAuditEvent(occurredAt: clock.now(), kind: .globalPauseChanged, detail: "paused"))

        let during = try await store.loadSnapshot()
        #expect(during.globallyPaused)
        #expect(during.pausedUntil == end)

        clock.set(end)
        for _ in 0..<2 {
            let after = try await store.loadSnapshot()
            #expect(!(after.globallyPaused))
            #expect(after.pausedUntil == nil)
        }
        let automatic = try await store.auditEvents().filter { $0.detail == "resumed automatically" }
        #expect(automatic.count == 1)
    }

    @Test func testSettingsPersistAndRetentionPrunesOnlyWhenEnabled() async throws {
        let clock = StoreTestClock(Date(timeIntervalSince1970: 10_000_000))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-SQLite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"), clock: clock)
        let initialSettings = try await store.loadSettings()
        #expect(initialSettings == .default)

        let old = TrashAuditEvent(occurredAt: clock.now().addingTimeInterval(-90 * 86_400), kind: .notDue)
        try await store.append(old)
        try await store.performMaintenance()
        let keptWhenDisabled = try await store.auditEvents().map(\.id)
        #expect(keptWhenDisabled.contains(old.id))

        let settings = AgentSettings(defaultGracePeriodSeconds: 120, protectHiddenFiles: true, activityRetentionDays: 30)
        let change = TrashAuditEvent(occurredAt: clock.now(), kind: .settingsChanged)
        try await store.updateSettings(settings, auditEvent: change)
        let persisted = try await store.loadSettings()
        #expect(persisted == settings)
        let afterChange = try await store.auditEvents().map(\.id)
        #expect(!(afterChange.contains(old.id)))
        #expect(afterChange.contains(change.id))
    }

    @Test func testEveryPolicyMutationBumpsRevisionAndStaleReplaceIsRejected() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let store = harness.store
        let initial = try await store.loadSnapshot()
        #expect(initial.revision == 0)

        let rule = try makeRule(name: "Rule")
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], globallyPaused: false), expectedRevision: 0)
        var revision = try await store.loadSnapshot().revision
        #expect(revision == 1)

        let keep = ItemPolicyOverride(path: "/Developer/keep", policy: .keep(protectDescendants: true))
        try await store.setOverrides([keep], removingPaths: [], auditEvents: [TrashAuditEvent(occurredAt: Date(), kind: .itemProtected)])
        #expect(try await store.loadSnapshot().revision == revision + 1)
        revision += 1
        try await store.setGlobalPause(true, auditEvent: TrashAuditEvent(occurredAt: Date(), kind: .globalPauseChanged))
        #expect(try await store.loadSnapshot().revision == revision + 1)
        revision += 1
        try await store.updateSettings(AgentSettings(protectHiddenFiles: true), auditEvent: TrashAuditEvent(occurredAt: Date(), kind: .settingsChanged))
        #expect(try await store.loadSnapshot().revision == revision + 1)
        revision += 1
        try await store.deleteRule(rule.id, auditEvent: TrashAuditEvent(occurredAt: Date(), kind: .ruleDeleted))
        #expect(try await store.loadSnapshot().revision == revision + 1)
        revision += 1

        // A client holding the old revision must not overwrite newer state, and nothing is written when it tries.
        let before = try await store.loadSnapshot()
        await #expect(throws: SQLiteSafetyStoreError.revisionConflict) {
            try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], globallyPaused: false), expectedRevision: revision - 1)
        }
        let after = try await store.loadSnapshot()
        #expect(after.revision == before.revision)
        #expect(after.rules.isEmpty)
        #expect(after.overrides == before.overrides)
    }

    @Test func testSetOverridesIsOneTransactionWithUpsertAndRemoval() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let store = harness.store
        let first = ItemPolicyOverride(path: "/Developer/a", policy: .keep(protectDescendants: false))
        let second = ItemPolicyOverride(path: "/Developer/b", policy: .keep(protectDescendants: false))
        try await store.setOverrides([first, second], removingPaths: [], auditEvents: [])
        let replacement = ItemPolicyOverride(path: "/Developer/a", policy: .keep(protectDescendants: true))
        let revisionBefore = try await store.loadSnapshot().revision

        try await store.setOverrides([replacement], removingPaths: ["/Developer/b/"], auditEvents: [TrashAuditEvent(occurredAt: Date(), kind: .itemProtected)])

        let snapshot = try await store.loadSnapshot()
        #expect(snapshot.overrides == [replacement])
        #expect(snapshot.revision == revisionBefore + 1)
    }

    @Test func testConditionalDeadlineRemovalKeepsFresherRowAndRuleDeletionIsRuleScoped() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let store = harness.store
        let keepRule = try makeRule(name: "Kept rule")
        let dropRule = try makeRule(name: "Dropped rule")
        try await store.replaceSnapshot(PolicySnapshot(rules: [keepRule, dropRule], overrides: [], globallyPaused: false))
        let identity = makeIdentity(resource: Data([1]), path: "/Developer/one.zip")
        let other = makeIdentity(resource: Data([2]), path: "/Developer/two.zip")
        let stale = makeDeadline(identity: identity, rule: keepRule, at: 10)
        let fresh = makeDeadline(identity: identity, rule: keepRule, at: 500)
        try await store.saveDeadline(fresh)
        try await store.saveDeadline(makeDeadline(identity: other, rule: dropRule, at: 20))

        let removedStale = try await store.removeDeadline(for: identity, scheduledAt: stale.scheduledAt)
        #expect(!removedStale)
        #expect(try await store.upcomingDeadlines().contains(fresh))

        try await store.deleteRule(dropRule.id, auditEvent: TrashAuditEvent(occurredAt: Date(), kind: .ruleDeleted))
        #expect(try await store.upcomingDeadlines() == [fresh])
        let removedFresh = try await store.removeDeadline(for: identity, scheduledAt: fresh.scheduledAt)
        #expect(removedFresh)
        #expect(try await store.nextDeadline() == nil)
    }

    @Test func testProjectActivityScanBeginDoesNotDestroyConcurrentScanObservations() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let store = harness.store
        let projectA = makeIdentity(resource: Data([21]), path: "/RootA/project")
        let projectB = makeIdentity(resource: Data([22]), path: "/RootB/project")
        let scanA = try await store.beginProjectActivityScan()
        try await store.recordProjectActivities([PersistedProjectActivity(identity: projectA, lastActivityAt: Date(timeIntervalSince1970: 10))], scanID: scanA)
        try await store.recordProjectObservations([ProjectActivityObservation(path: "/RootA/project/src/file", modifiedAt: Date(timeIntervalSince1970: 900))], scanID: scanA)

        // A second root begins scanning while the first is still in flight.
        let scanB = try await store.beginProjectActivityScan()
        try await store.recordProjectActivities([PersistedProjectActivity(identity: projectB, lastActivityAt: Date(timeIntervalSince1970: 20))], scanID: scanB)
        try await store.finishProjectActivityScan(scanID: scanB, atOrBelow: "/RootB")
        try await store.finishProjectActivityScan(scanID: scanA, atOrBelow: "/RootA")

        // Scan A's observation survived scan B starting and was folded into project A.
        #expect(try await store.projectActivity(for: "/RootA/project/src") == Date(timeIntervalSince1970: 900))
        #expect(try await store.projectActivity(for: "/RootB/project") == Date(timeIntervalSince1970: 20))
    }

    @Test func testInterruptedTrashAttemptsAreReconciledOnceAndCompletedOnesAreNot() async throws {
        let clock = StoreTestClock(Date(timeIntervalSince1970: 5_000))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-SQLite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"), clock: clock)
        let interrupted = makeIdentity(resource: Data([31]), path: "/Developer/interrupted.zip")
        let finished = makeIdentity(resource: Data([32]), path: "/Developer/finished.zip")
        try await store.append(TrashAuditEvent(occurredAt: Date(timeIntervalSince1970: 100), kind: .trashAttempted, identity: interrupted))
        try await store.append(TrashAuditEvent(occurredAt: Date(timeIntervalSince1970: 101), kind: .trashAttempted, identity: finished))
        try await store.append(TrashAuditEvent(occurredAt: Date(timeIntervalSince1970: 102), kind: .movedToTrash, identity: finished))

        #expect(try await store.reconcileInterruptedTrashAttempts() == 1)
        #expect(try await store.reconcileInterruptedTrashAttempts() == 0)

        let failures = try await store.auditEvents().filter { $0.kind == .trashFailed }
        #expect(failures.count == 1)
        #expect(failures.first?.identity == interrupted)
    }

    @Test func testDeviceFallbackIdentitiesAreNotRestoredAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-SQLite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let rule = try makeRule(name: "Rule")
        let volatile = FilesystemIdentity(
            volumeIdentifier: UUID(), resourceIdentifier: Data([41]), pathHint: "/Developer/volatile.zip", isPersistent: false
        )
        let stable = makeIdentity(resource: Data([42]), path: "/Developer/stable.zip")
        do {
            let store = try SQLiteSafetyStore(databaseURL: url)
            try await store.saveDeadline(makeDeadline(identity: volatile, rule: rule, at: 10))
            try await store.saveDeadline(makeDeadline(identity: stable, rule: rule, at: 20))
            #expect(try await store.indexedDeadlineCount() == 2)
        }
        let reopened = try SQLiteSafetyStore(databaseURL: url)
        #expect(try await reopened.upcomingDeadlines().map(\.identity) == [stable])
    }

    @Test func testManagedRootBookmarkRefreshKeepsRootAndBumpsRevision() async throws {
        let harness = try makeStore()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let store = harness.store
        let root = try ManagedRoot(displayName: "Developer", path: "/Developer", bookmarkData: Data([1]))
        try await store.replaceSnapshot(PolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: false))
        let revision = try await store.loadSnapshot().revision

        try await store.updateManagedRootBookmark(rootID: root.id, bookmarkData: Data([9, 9]), auditEvent: nil)

        let snapshot = try await store.loadSnapshot()
        #expect(snapshot.managedRoots.map(\.bookmarkData) == [Data([9, 9])])
        #expect(snapshot.managedRoots.first?.path == root.path)
        #expect(snapshot.revision == revision + 1)
    }

    private func makeDeadline(identity: FilesystemIdentity, rule: LifetimeRule, at seconds: TimeInterval) -> PersistedDeadline {
        let when = Date(timeIntervalSince1970: seconds)
        let explanation = CandidateExplanation(
            candidate: RuleCandidate(identity: identity, name: "item.zip", kind: .file, timestamps: CandidateTimestamps(modified: when)),
            rule: rule, basisDate: when, eligibleAt: when, scheduledAt: when, disposition: .active
        )
        return PersistedDeadline(identity: identity, scheduledAt: when, explanation: explanation)
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

private final class StoreTestClock: SafetyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { lock.withLock { instant } }
    func set(_ value: Date) { lock.withLock { instant = value } }
}
