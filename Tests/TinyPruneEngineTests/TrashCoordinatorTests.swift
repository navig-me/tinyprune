#if canImport(XCTest)
import XCTest
@testable import TinyPruneDomain
@testable import TinyPruneEngine

final class TrashCoordinatorTests: XCTestCase {
    func testPreviewNeverCallsTrashAndRecordsPreviewEvent() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .preview)
        let harness = makeCoordinator(candidate: candidate, rules: [rule])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        XCTAssertEqual(outcome, .previewed)
        let previewMoves = await harness.fileAccess.moveCount()
        let previewEvents = await harness.audit.events()
        XCTAssertEqual(previewMoves, 0)
        XCTAssertEqual(previewEvents.map(\.kind), [.previewSkipped])
    }

    func testActiveDueCandidateMovesOnlyAfterFinalPreflight() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        XCTAssertEqual(outcome, .movedToTrash(originalPath: candidate.identity.pathHint, trashedPath: "/.Trash/node_modules"))
        let activeMoves = await harness.fileAccess.moveCount()
        let activeEvents = await harness.audit.events()
        XCTAssertEqual(activeMoves, 1)
        XCTAssertEqual(activeEvents.map(\.kind), [.trashAttempted, .movedToTrash])
    }

    func testCurrentKeepOverrideBlocksPreviouslyScheduledMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))
        let harness = makeCoordinator(candidate: candidate, rules: [rule], overrides: [keep])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        guard case .skipped = outcome else { return XCTFail("Expected final preflight to skip the newly protected candidate") }
        let moves = await harness.fileAccess.moveCount()
        XCTAssertEqual(moves, 0)
    }

    func testReplacementAtSamePathCannotBeMoved() async throws {
        let scheduledCandidate = makeCandidate(resource: Data([1]))
        let replacement = makeCandidate(resource: Data([2]))
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: replacement, rules: [rule])

        let outcome = try await harness.coordinator.execute(request(for: scheduledCandidate, rule: rule))

        XCTAssertEqual(outcome, .skipped("filesystem identity changed"))
        let moves = await harness.fileAccess.moveCount()
        XCTAssertEqual(moves, 0)
    }

    func testProtectedDescendantPreventsParentTrash() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], protectedDescendant: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        XCTAssertEqual(outcome, .skipped("folder contains a protected descendant"))
        let moves = await harness.fileAccess.moveCount()
        XCTAssertEqual(moves, 0)
    }

    func testKeepAddedDuringTrashAuditClosesFinalPreflightRace() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))
        let store = MockPolicyStore(snapshot: PolicySnapshot(rules: [rule], overrides: [], globallyPaused: false))
        let audit = PolicyFlipAudit(store: store, replacement: PolicySnapshot(rules: [rule], overrides: [keep], globallyPaused: false))
        let fileAccess = MockTrashFileAccess(candidate: candidate, protectedDescendant: false, trashError: nil)
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: audit, clock: FixedClock(Date(timeIntervalSinceReferenceDate: 1_000)))

        let outcome = try await coordinator.execute(request(for: candidate, rule: rule))

        XCTAssertEqual(outcome, .skipped("policy changed at the Trash boundary"))
        let moves = await fileAccess.moveCount()
        let events = await audit.events()
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(events.map(\.kind), [.trashAttempted, .safetySkipped])
    }

    func testGlobalPauseAtExecutionTimeBlocksMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], globallyPaused: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        XCTAssertEqual(outcome, .skipped("candidate is no longer eligible"))
        let moves = await harness.fileAccess.moveCount()
        XCTAssertEqual(moves, 0)
    }

    func testChangedDeadlineAndFutureDeadlineBlockMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active, lifetime: 200)
        let staleRequest = TrashRequest(candidateIdentity: candidate.identity, source: .rule(rule.id), scheduledAt: Date(timeIntervalSinceReferenceDate: 100))
        let staleHarness = makeCoordinator(candidate: candidate, rules: [rule])
        let staleOutcome = try await staleHarness.coordinator.execute(staleRequest)
        XCTAssertEqual(staleOutcome, .skipped("scheduled deadline changed"))
        let staleMoves = await staleHarness.fileAccess.moveCount()
        XCTAssertEqual(staleMoves, 0)

        let dueRequest = TrashRequest(candidateIdentity: candidate.identity, source: .rule(rule.id), scheduledAt: Date(timeIntervalSinceReferenceDate: 200))
        let futureHarness = makeCoordinator(candidate: candidate, rules: [rule], now: Date(timeIntervalSinceReferenceDate: 150))
        let futureOutcome = try await futureHarness.coordinator.execute(dueRequest)
        XCTAssertEqual(futureOutcome, .notDue(Date(timeIntervalSinceReferenceDate: 200)))
        let futureMoves = await futureHarness.fileAccess.moveCount()
        XCTAssertEqual(futureMoves, 0)
    }

    func testTrashFailureIsAuditedAndReturnedAsFailure() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], trashError: StubError.failed)

        do {
            _ = try await harness.coordinator.execute(request(for: candidate, rule: rule))
            XCTFail("Expected Trash failure")
        } catch let error as TrashExecutionError {
            guard case .filesystemOperationFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let failureMoves = await harness.fileAccess.moveCount()
        let failureEvents = await harness.audit.events()
        XCTAssertEqual(failureMoves, 1)
        XCTAssertEqual(failureEvents.map(\.kind), [.trashAttempted, .trashFailed])
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
#endif
