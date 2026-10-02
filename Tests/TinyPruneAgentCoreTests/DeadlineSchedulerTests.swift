import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

@Suite struct DeadlineSchedulerTests {
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
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], globallyPaused: false))
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
        await scheduler.start()
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
    private let candidate: RuleCandidate
    private let onMove: @Sendable () -> Void

    init(candidate: RuleCandidate, onMove: @escaping @Sendable () -> Void) {
        self.candidate = candidate
        self.onMove = onMove
    }

    func inspect(path: String) async throws -> RuleCandidate? {
        path == candidate.identity.pathHint ? candidate : nil
    }

    func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride]) async throws -> Bool { false }

    func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String {
        guard expectedIdentity == candidate.identity else { throw SchedulerTestError.identityChanged }
        onMove()
        return "/.Trash/\(UUID().uuidString)"
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
}
