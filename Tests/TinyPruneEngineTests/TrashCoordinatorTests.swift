import Testing
import Foundation
@testable import TinyPruneDomain
@testable import TinyPruneEngine

@Suite struct TrashCoordinatorTests {
    @Test func testPreviewNeverCallsTrashAndRecordsPreviewEvent() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .preview)
        let harness = makeCoordinator(candidate: candidate, rules: [rule])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .previewed)
        let previewMoves = await harness.fileAccess.moveCount()
        let previewEvents = await harness.audit.events()
        #expect(previewMoves == 0)
        #expect(previewEvents.map(\.kind) == [.previewSkipped])
    }

    @Test func testActiveDueCandidateMovesOnlyAfterFinalPreflight() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .movedToTrash(originalPath: candidate.identity.pathHint, trashedPath: "/.Trash/node_modules"))
        let activeMoves = await harness.fileAccess.moveCount()
        let activeEvents = await harness.audit.events()
        #expect(activeMoves == 1)
        #expect(activeEvents.map(\.kind) == [.trashAttempted, .movedToTrash])
    }

    @Test func testCurrentKeepOverrideBlocksPreviouslyScheduledMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))
        let harness = makeCoordinator(candidate: candidate, rules: [rule], overrides: [keep])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        guard case .skipped = outcome else { Issue.record("Expected final preflight to skip the newly protected candidate"); return }
        let moves = await harness.fileAccess.moveCount()
        #expect(moves == 0)
    }

    @Test func testReplacementAtSamePathCannotBeMoved() async throws {
        let scheduledCandidate = makeCandidate(resource: Data([1]))
        let replacement = makeCandidate(resource: Data([2]))
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: replacement, rules: [rule])

        let outcome = try await harness.coordinator.execute(request(for: scheduledCandidate, rule: rule))

        #expect(outcome == .skipped("filesystem identity changed"))
        let moves = await harness.fileAccess.moveCount()
        #expect(moves == 0)
    }

    @Test func testProtectedDescendantPreventsParentTrash() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], protectedDescendant: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("folder contains a protected descendant"))
        let moves = await harness.fileAccess.moveCount()
        #expect(moves == 0)
    }

    @Test func testKeepAddedDuringTrashAuditClosesFinalPreflightRace() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))
        let store = MockPolicyStore(snapshot: PolicySnapshot(rules: [rule], overrides: [], globallyPaused: false))
        let audit = PolicyFlipAudit(store: store, replacement: PolicySnapshot(rules: [rule], overrides: [keep], globallyPaused: false))
        let fileAccess = MockTrashFileAccess(candidate: candidate, protectedDescendant: false, trashError: nil)
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: audit, clock: FixedClock(Date(timeIntervalSinceReferenceDate: 1_000)))

        let outcome = try await coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("policy changed at the Trash boundary"))
        let moves = await fileAccess.moveCount()
        let events = await audit.events()
        #expect(moves == 0)
        #expect(events.map(\.kind) == [.trashAttempted, .safetySkipped])
    }

    @Test func testGlobalPauseAtExecutionTimeBlocksMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], globallyPaused: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("candidate is no longer eligible"))
        let moves = await harness.fileAccess.moveCount()
        #expect(moves == 0)
    }

    @Test func testChangedDeadlineAndFutureDeadlineBlockMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active, lifetime: 200)
        let staleRequest = TrashRequest(candidateIdentity: candidate.identity, source: .rule(rule.id), scheduledAt: Date(timeIntervalSinceReferenceDate: 100))
        let staleHarness = makeCoordinator(candidate: candidate, rules: [rule])
        let staleOutcome = try await staleHarness.coordinator.execute(staleRequest)
        #expect(staleOutcome == .skipped("scheduled deadline changed"))
        let staleMoves = await staleHarness.fileAccess.moveCount()
        #expect(staleMoves == 0)

        let dueRequest = TrashRequest(candidateIdentity: candidate.identity, source: .rule(rule.id), scheduledAt: Date(timeIntervalSinceReferenceDate: 200))
        let futureHarness = makeCoordinator(candidate: candidate, rules: [rule], now: Date(timeIntervalSinceReferenceDate: 150))
        let futureOutcome = try await futureHarness.coordinator.execute(dueRequest)
        #expect(futureOutcome == .notDue(Date(timeIntervalSinceReferenceDate: 200)))
        let futureMoves = await futureHarness.fileAccess.moveCount()
        #expect(futureMoves == 0)
    }

    @Test func testTrashFailureIsAuditedAndReturnedAsFailure() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], trashError: StubError.failed)

        do {
            _ = try await harness.coordinator.execute(request(for: candidate, rule: rule))
            Issue.record("Expected Trash failure")
        } catch let error as TrashExecutionError {
            guard case .filesystemOperationFailed = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        let failureMoves = await harness.fileAccess.moveCount()
        let failureEvents = await harness.audit.events()
        #expect(failureMoves == 1)
        #expect(failureEvents.map(\.kind) == [.trashAttempted, .trashFailed])
    }

    private func makeCoordinator(
        candidate: RuleCandidate,
        rules: [LifetimeRule],
        overrides: [ItemPolicyOverride] = [],
        globallyPaused: Bool = false,
        protectedDescendant: Bool = false,
        trashError: Error? = nil,
        now: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) -> (coordinator: TrashCoordinator, fileAccess: MockTrashFileAccess, audit: MockAudit) {
        let fileAccess = MockTrashFileAccess(candidate: candidate, protectedDescendant: protectedDescendant, trashError: trashError)
        let audit = MockAudit()
        let coordinator = TrashCoordinator(
            policyStore: MockPolicyStore(snapshot: PolicySnapshot(rules: rules, overrides: overrides, globallyPaused: globallyPaused)),
            fileAccess: fileAccess,
            audit: audit,
            clock: FixedClock(now)
        )
        return (coordinator, fileAccess, audit)
    }

    private func makeRule(state: RuleState, lifetime: TimeInterval = 100) throws -> LifetimeRule {
        try LifetimeRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "Old Node Modules",
            scope: try RuleScope(path: "/Developer", recursive: true),
            matcher: try ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
            expiryBasis: .modified,
            lifetime: try RuleDuration(seconds: lifetime),
            action: .trashItem,
            state: state
        )
    }

    private func makeCandidate(resource: Data = Data([1, 2])) -> RuleCandidate {
        RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, resourceIdentifier: resource, pathHint: "/Developer/project/node_modules"),
            name: "node_modules",
            kind: .directory,
            timestamps: CandidateTimestamps(modified: Date(timeIntervalSinceReferenceDate: 0))
        )
    }

    private func request(for candidate: RuleCandidate, rule: LifetimeRule) -> TrashRequest {
        TrashRequest(candidateIdentity: candidate.identity, source: .rule(rule.id), scheduledAt: Date(timeIntervalSinceReferenceDate: 100))
    }
}

private enum StubError: Error {
    case failed
}

private struct FixedClock: SafetyClock {
    let value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

private actor MockPolicyStore: PolicySnapshotProviding {
    private var snapshot: PolicySnapshot
    init(snapshot: PolicySnapshot) { self.snapshot = snapshot }
    func loadSnapshot() async throws -> PolicySnapshot { snapshot }
    func replace(_ snapshot: PolicySnapshot) { self.snapshot = snapshot }
}

private actor MockTrashFileAccess: TrashFileAccess {
    let candidate: RuleCandidate
    let protectedDescendant: Bool
    let trashError: Error?
    private(set) var moves = 0

    init(candidate: RuleCandidate, protectedDescendant: Bool, trashError: Error?) {
        self.candidate = candidate
        self.protectedDescendant = protectedDescendant
        self.trashError = trashError
    }

    func inspect(path: String) async throws -> RuleCandidate? { candidate }
    func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride]) async throws -> Bool { protectedDescendant }
    func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String {
        moves += 1
        if let trashError { throw trashError }
        return "/.Trash/\(URL(fileURLWithPath: path).lastPathComponent)"
    }
    func moveCount() -> Int { moves }
}

private actor MockAudit: TrashAuditRecording {
    private(set) var recorded: [TrashAuditEvent] = []
    func append(_ event: TrashAuditEvent) async throws { recorded.append(event) }
    func events() -> [TrashAuditEvent] { recorded }
}
private actor PolicyFlipAudit: TrashAuditRecording {
    private let store: MockPolicyStore
    private let replacement: PolicySnapshot
    private var recorded: [TrashAuditEvent] = []
    private var didFlip = false

    init(store: MockPolicyStore, replacement: PolicySnapshot) {
        self.store = store
        self.replacement = replacement
    }

    func append(_ event: TrashAuditEvent) async throws {
        recorded.append(event)
        if event.kind == .trashAttempted && !didFlip {
            didFlip = true
            await store.replace(replacement)
        }
    }

    func events() -> [TrashAuditEvent] { recorded }
}
