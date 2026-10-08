import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence
import TinyPruneIPC

@Suite struct DeadlineSchedulerTests {
    @Test func updateBlockPreservesDeadlineAndMarkerRemovalWakesCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPruneUpdateScheduler-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        let candidate = RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([42]), pathHint: "/Developer/update.tmp"),
            name: "update.tmp", kind: .file, timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 1_000))
        )
        let rule = try LifetimeRule(
            name: "Update fixture", scope: RuleScope(path: "/Developer", recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: ["update.tmp"]),
            expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .trashItem, state: .active
        )
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [Self.developerRoot()], globallyPaused: false))
        let deadline = makeDeadline(candidate: candidate, rule: rule, scheduledAt: Date(timeIntervalSince1970: 1_010))
        try await store.saveDeadline(deadline)
        let updater = UpdateInstallationGate(directory: directory.appendingPathComponent("gate"))
        try updater.beginInstallation(targetVersion: "2", currentVersion: "1")
        let moved = TestExpectation("marker removal wakes retained due cleanup")
        let signal = SchedulerActionSignal(expectation: moved)
        let access = SchedulerTrashFileAccess(candidate: candidate) { signal.recordMove() }
        let blocked = TestExpectation("scheduler observes pending update")
        let audit = UpdateBlockAudit(store: store, blocked: blocked)
        let coordinator = TrashCoordinator(
            policyStore: store, fileAccess: access, audit: audit,
            clock: MutableSchedulerClock(Date(timeIntervalSince1970: 1_010)),
            updateGate: UpdateInstallationGate(directory: directory.appendingPathComponent("gate"))
        )
        let scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: MutableSchedulerClock(Date(timeIntervalSince1970: 1_010)))
        try await scheduler.start()
        await blocked.expectFulfilled(timeout: 5)
        #expect(try await store.nextDeadline() == deadline)
        #expect(signal.moveCount == 0)
        try updater.finishInstallation()
        await moved.expectFulfilled(timeout: 5)
        // Stop drains the worker's wakeup; runDueNow serializes the final deadline-removal state.
        await scheduler.stop()
        try await scheduler.runDueNow()
        #expect(try await store.nextDeadline() == nil)
        #expect(signal.moveCount == 1)
    }

    @Test func testSignalReplacesFutureDeadlineAndRunsOnlyOnePreflight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        let identity = FilesystemIdentity(
            volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            resourceIdentifier: Data([31]),
            pathHint: "/Developer/candidate.tmp"
        )
        let candidate = RuleCandidate(
            identity: identity,
            name: "candidate.tmp",
            kind: .file,
            timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: 1_000))
        )
        let rule = try LifetimeRule(
            name: "Temporary file",
            scope: RuleScope(path: "/Developer", recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: ["candidate.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 10),
            action: .trashItem,
            state: .active
        )
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [Self.developerRoot()], globallyPaused: false))
        try await store.saveDeadline(makeDeadline(candidate: candidate, rule: rule, scheduledAt: Date(timeIntervalSince1970: 100_000)))

        let clock = MutableSchedulerClock(Date(timeIntervalSince1970: 1_000))
        let moved = TestExpectation("scheduler executes updated due deadline")
        let actionSignal = SchedulerActionSignal(expectation: moved)
        let fileAccess = SchedulerTrashFileAccess(candidate: candidate) { actionSignal.recordMove() }
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: store, clock: clock)
        let waiting = TestExpectation("scheduler is sleeping until the future deadline")
        let waitSignal = SchedulerWaitSignal(expectation: waiting)
        let scheduler = DeadlineScheduler(
            store: store,
            coordinator: coordinator,
            clock: clock,
            onWaitingForDeadline: { waitSignal.signal() }
        )
        try await scheduler.start()
        await waiting.expectFulfilled(timeout: 5)

        clock.set(Date(timeIntervalSince1970: 1_010))
        try await store.saveDeadline(makeDeadline(candidate: candidate, rule: rule, scheduledAt: Date(timeIntervalSince1970: 1_010)))
        await scheduler.signalChange()
        await moved.expectFulfilled(timeout: 5)
        try await scheduler.runDueNow()

        let remaining = try await store.nextDeadline()
        #expect(remaining == nil)
        #expect(actionSignal.moveCount == 1)
        await scheduler.signalChange()
        try await scheduler.runDueNow()
        #expect(actionSignal.moveCount == 1)
        await scheduler.stop()
    }

    @Test func pausedRuleDefersAndKeepsDeadlineUntilResumed() async throws {
        let fixture = try await SchedulerFixture(state: .paused)
        defer { fixture.cleanUp() }
        let candidate = fixture.candidate(named: "a.tmp", modified: 1_000)
        try await fixture.store.saveDeadline(fixture.deadline(for: candidate, scheduledAt: 1_010))
        fixture.clock.set(Date(timeIntervalSince1970: 1_100))

        try await fixture.scheduler.runDueNow()
        #expect(try await fixture.store.nextDeadline()?.scheduledAt == Date(timeIntervalSince1970: 1_010))
        #expect(await fixture.access.moveCount(for: candidate.identity.pathHint) == 0)

        // Resuming the rule signals a change; the retained deadline then executes without re-indexing.
        let active = try fixture.rule(state: .active)
        try await fixture.store.replaceSnapshot(PolicySnapshot(rules: [active], overrides: [], managedRoots: [Self.developerRoot()], globallyPaused: false))
        await fixture.scheduler.signalChange()
        try await fixture.scheduler.runDueNow()
        #expect(try await fixture.store.nextDeadline() == nil)
        #expect(await fixture.access.moveCount(for: candidate.identity.pathHint) == 1)
    }

    @Test func poisonDeadlineBacksOffAndNeverBlocksOtherDueItems() async throws {
        let fixture = try await SchedulerFixture(state: .active)
        defer { fixture.cleanUp() }
        let poison = fixture.candidate(named: "poison.tmp", modified: 1_000)
        let healthy = fixture.candidate(named: "healthy.tmp", modified: 1_000)
        try await fixture.store.saveDeadlines([
            fixture.deadline(for: poison, scheduledAt: 1_010),
            fixture.deadline(for: healthy, scheduledAt: 1_010)
        ])
        await fixture.access.fail(path: poison.identity.pathHint, true)
        fixture.clock.set(Date(timeIntervalSince1970: 1_100))

        try await fixture.scheduler.runDueNow()
        #expect(await fixture.access.moveCount(for: healthy.identity.pathHint) == 1)
        #expect(try await fixture.store.nextDeadline()?.identity == poison.identity)
        #expect(await fixture.access.inspectCount(for: poison.identity.pathHint) == 1)

        // Still inside the backoff window: not retried.
        try await fixture.scheduler.runDueNow()
        #expect(await fixture.access.inspectCount(for: poison.identity.pathHint) == 1)

        // After the backoff elapses on the injected clock it is retried and, once healthy, trashed.
        await fixture.access.fail(path: poison.identity.pathHint, false)
        fixture.clock.set(Date(timeIntervalSince1970: 1_131))
        try await fixture.scheduler.runDueNow()
        #expect(await fixture.access.moveCount(for: poison.identity.pathHint) == 1)
        #expect(try await fixture.store.nextDeadline() == nil)
    }

    @Test func movedDeadlineRowSurvivesCompletionOfStaleExecution() async throws {
        let fixture = try await SchedulerFixture(state: .active)
        defer { fixture.cleanUp() }
        let candidate = fixture.candidate(named: "fresh.tmp", modified: 1_000)
        let stale = fixture.deadline(for: candidate, scheduledAt: 1_010)
        let fresh = fixture.deadline(for: candidate, scheduledAt: 9_000)
        try await fixture.store.saveDeadline(fresh)

        try await fixture.store.removeDeadline(for: stale.identity, scheduledAt: stale.scheduledAt)

        #expect(try await fixture.store.nextDeadline() == fresh)
    }

    static func developerRoot() -> ManagedRoot {
        try! ManagedRoot(displayName: "Developer", path: "/Developer", bookmarkData: Data([1]))
    }

    private func makeDeadline(candidate: RuleCandidate, rule: LifetimeRule, scheduledAt: Date) -> PersistedDeadline {
        let basis = candidate.timestamps.modified!
        let eligible = basis.addingTimeInterval(rule.lifetime.seconds)
        let explanation = CandidateExplanation(
            candidate: candidate,
            rule: rule,
            basisDate: basis,
            eligibleAt: eligible,
            scheduledAt: scheduledAt,
            disposition: .active
        )
        return PersistedDeadline(identity: candidate.identity, scheduledAt: scheduledAt, explanation: explanation)
    }
}

private final class SchedulerActionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: TestExpectation
    private var count = 0

    init(expectation: TestExpectation) { self.expectation = expectation }

    var moveCount: Int { lock.withLock { count } }

    func recordMove() {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        if first { expectation.fulfill() }
    }
}

private final class SchedulerWaitSignal: @unchecked Sendable {
    private let expectation: TestExpectation
    init(expectation: TestExpectation) { self.expectation = expectation }
    func signal() { expectation.fulfill() }
}

private actor SchedulerTrashFileAccess: TrashFileAccess {
    private let candidates: [String: RuleCandidate]
    private let onMove: @Sendable () -> Void
    private var failing: Set<String> = []
    private var inspects: [String: Int] = [:]
    private var moves: [String: Int] = [:]

    init(candidate: RuleCandidate, onMove: @escaping @Sendable () -> Void) {
        self.candidates = [candidate.identity.pathHint: candidate]
        self.onMove = onMove
    }

    init(candidates: [RuleCandidate]) {
        self.candidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.identity.pathHint, $0) })
        self.onMove = {}
    }

    func fail(path: String, _ shouldFail: Bool) {
        if shouldFail { failing.insert(path) } else { failing.remove(path) }
    }
    func moveCount(for path: String) -> Int { moves[path, default: 0] }
    func inspectCount(for path: String) -> Int { inspects[path, default: 0] }

    func inspect(path: String) async throws -> RuleCandidate? {
        inspects[path, default: 0] += 1
        if failing.contains(path) { throw SchedulerTestError.injected }
        return candidates[path]
    }

    func hasSymbolicLinkAncestor(of path: String, below rootPath: String) async throws -> Bool { false }

    func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride], protectHiddenFiles: Bool, budget: DescendantWalkBudget) async throws -> DescendantProtection { .none }

    func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String {
        guard let candidate = candidates[path], expectedIdentity == candidate.identity else { throw SchedulerTestError.identityChanged }
        moves[path, default: 0] += 1
        onMove()
        return "/.Trash/\(UUID().uuidString)"
    }
}

/// Real store + coordinator + scheduler on an injected clock with a scriptable file access.
private struct SchedulerFixture {
    let directory: URL
    let store: SQLiteSafetyStore
    let clock: MutableSchedulerClock
    let access: SchedulerTrashFileAccess
    let scheduler: DeadlineScheduler
    private let ruleID = UUID()

    init(state: RuleState) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-SchedulerFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        clock = MutableSchedulerClock(Date(timeIntervalSince1970: 1_000))
        let all = ["a.tmp", "poison.tmp", "healthy.tmp", "fresh.tmp"].map { Self.makeCandidate(named: $0, modified: 1_000) }
        access = SchedulerTrashFileAccess(candidates: all)
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: access, audit: store, clock: clock)
        scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: clock)
        let rule = try Self.makeRule(id: ruleID, state: state)
        let snapshot = PolicySnapshot(rules: [rule], overrides: [], managedRoots: [DeadlineSchedulerTests.developerRoot()], globallyPaused: false)
        try await store.replaceSnapshot(snapshot)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func rule(state: RuleState) throws -> LifetimeRule { try Self.makeRule(id: ruleID, state: state) }

    func candidate(named name: String, modified: TimeInterval) -> RuleCandidate { Self.makeCandidate(named: name, modified: modified) }

    func deadline(for candidate: RuleCandidate, scheduledAt: TimeInterval) -> PersistedDeadline {
        let rule = try! Self.makeRule(id: ruleID, state: .active)
        let basis = candidate.timestamps.modified!
        let explanation = CandidateExplanation(
            candidate: candidate, rule: rule, basisDate: basis,
            eligibleAt: basis.addingTimeInterval(rule.lifetime.seconds),
            scheduledAt: Date(timeIntervalSince1970: scheduledAt), disposition: .active
        )
        return PersistedDeadline(identity: candidate.identity, scheduledAt: Date(timeIntervalSince1970: scheduledAt), explanation: explanation)
    }

    private static func makeCandidate(named name: String, modified: TimeInterval) -> RuleCandidate {
        let seed = UInt8(truncatingIfNeeded: name.hashValue & 0xff)
        return RuleCandidate(
            identity: FilesystemIdentity(
                volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                resourceIdentifier: Data(name.utf8) + Data([seed]),
                pathHint: "/Developer/\(name)"
            ),
            name: name, kind: .file,
            timestamps: CandidateTimestamps(modified: Date(timeIntervalSince1970: modified))
        )
    }

    private static func makeRule(id: UUID, state: RuleState) throws -> LifetimeRule {
        try LifetimeRule(
            id: id, name: "Scheduler fixture", scope: RuleScope(path: "/Developer", recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: ["a.tmp", "poison.tmp", "healthy.tmp", "fresh.tmp"]),
            expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .trashItem, state: state
        )
    }
}

private final class MutableSchedulerClock: SafetyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { lock.withLock { instant } }
    func set(_ instant: Date) { lock.withLock { self.instant = instant } }
}

private enum SchedulerTestError: Error {
    case identityChanged
    case injected
}

private struct UpdateBlockAudit: TrashAuditRecording {
    let store: SQLiteSafetyStore
    let blocked: TestExpectation

    func append(_ event: TrashAuditEvent) async throws {
        try await store.append(event)
        if event.kind == .safetySkipped { blocked.fulfill() }
    }
}
