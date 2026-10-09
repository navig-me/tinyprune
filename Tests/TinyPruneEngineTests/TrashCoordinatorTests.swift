import Testing
import Foundation
@testable import TinyPruneDomain
@testable import TinyPruneEngine
import TinyPruneIPC

@Suite struct TrashCoordinatorTests {
    @Test func pendingAppUpdateBlocksCleanupUntilCanceled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPruneEngineUpdate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = UpdateInstallationGate(directory: directory)
        try updater.beginInstallation(targetVersion: "2", currentVersion: "1")
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let store = MockPolicyStore(snapshot: PolicySnapshot(rules: [rule], overrides: [], managedRoots: [try makeRoot()], globallyPaused: false))
        let audit = MockAudit()
        let access = MockTrashFileAccess(candidate: candidate, walkResult: DescendantProtection.none, symlinkAncestor: false, trashError: nil)
        let coordinator = TrashCoordinator(
            policyStore: store, fileAccess: access, audit: audit,
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 1_000)),
            updateGate: UpdateInstallationGate(directory: directory)
        )
        await #expect(throws: TrashExecutionError.updateInstallationPending) {
            try await coordinator.execute(request(for: candidate, rule: rule))
        }
        #expect(await access.moveCount() == 0)
        #expect(await audit.events().map(\.kind) == [.safetySkipped])
        try updater.finishInstallation()
        let resumed = try await coordinator.execute(request(for: candidate, rule: rule))
        #expect(resumed == .movedToTrash(originalPath: candidate.identity.pathHint, trashedPath: "/.Trash/node_modules"))
        #expect(await access.moveCount() == 1)
    }

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

    @Test func testKeepAddedBeforeFinalPolicyReloadBlocksMoveAndWritesNoAttempt() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let root = try makeRoot()
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))
        let store = SequencedPolicyStore(snapshots: [
            PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false),
            PolicySnapshot(rules: [rule], overrides: [keep], managedRoots: [root], globallyPaused: false)
        ])
        let audit = MockAudit()
        let fileAccess = MockTrashFileAccess(candidate: candidate, walkResult: DescendantProtection.none, symlinkAncestor: false, trashError: nil)
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: audit, clock: FixedClock(Date(timeIntervalSinceReferenceDate: 1_000)))

        let outcome = try await coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("item is protected by Keep"))
        #expect(await fileAccess.moveCount() == 0)
        // The attempt is only audited once every check has passed, so a blocked move leaves no dangling attempt.
        #expect(await audit.events().map(\.kind) == [.safetySkipped])
    }

    @Test func testAttemptIsAuditedImmediatelyBeforeMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule])

        _ = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(await harness.audit.events().map(\.kind) == [.trashAttempted, .movedToTrash])
        #expect(await harness.fileAccess.eventLog() == ["inspect", "inspect", "move"])
    }

    @Test func testItemOutsideEveryManagedRootIsSkipped() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let otherRoot = try ManagedRoot(displayName: "Other", path: "/Elsewhere", bookmarkData: Data([1]))
        let harness = makeCoordinator(candidate: candidate, rules: [rule], managedRoots: [otherRoot])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("item is outside every managed root"))
        #expect(await harness.fileAccess.moveCount() == 0)
    }

    @Test func testManagedRootItselfIsNotAnItemInsideTheRoot() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let root = try ManagedRoot(displayName: "Self", path: candidate.identity.pathHint, bookmarkData: Data([1]))
        let harness = makeCoordinator(candidate: candidate, rules: [rule], managedRoots: [root])

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("item is outside every managed root"))
    }

    @Test func testSymbolicLinkAncestorBelowRootIsSkipped() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], symlinkAncestor: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("item is reached through a symbolic link"))
        #expect(await harness.fileAccess.moveCount() == 0)
    }

    @Test func testPausedRuleAndGlobalPauseAreDeferredNotTerminal() async throws {
        let candidate = makeCandidate()
        let pausedRule = try makeRule(state: .paused)
        let pausedHarness = makeCoordinator(candidate: candidate, rules: [pausedRule])
        #expect(try await pausedHarness.coordinator.execute(request(for: candidate, rule: pausedRule)) == .deferred("rule is paused"))

        let activeRule = try makeRule(state: .active)
        let globalHarness = makeCoordinator(candidate: candidate, rules: [activeRule], globallyPaused: true)
        #expect(try await globalHarness.coordinator.execute(request(for: candidate, rule: activeRule)) == .deferred("pruning is paused"))
        #expect(await globalHarness.fileAccess.moveCount() == 0)
        #expect(await globalHarness.audit.events().isEmpty)
    }

    @Test func testDeletedRuleIsTerminalSkip() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [])

        #expect(try await harness.coordinator.execute(request(for: candidate, rule: rule)) == .skipped("rule no longer exists"))
    }

    @Test func testPersistedActivityHydrationLetsObservedBasisRuleExecute() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active, basis: .firstObserved)
        let observed = Date(timeIntervalSinceReferenceDate: 0)
        let hydrated = RuleCandidate(
            identity: candidate.identity, name: candidate.name, kind: candidate.kind,
            timestamps: CandidateTimestamps(modified: candidate.timestamps.modified, firstObserved: observed)
        )
        let hydratedHarness = makeCoordinator(candidate: candidate, rules: [rule], hydrated: hydrated)
        let outcome = try await hydratedHarness.coordinator.execute(request(for: candidate, rule: rule))
        #expect(outcome == .movedToTrash(originalPath: candidate.identity.pathHint, trashedPath: "/.Trash/node_modules"))

        // Without persisted activity the basis timestamp is missing and nothing may move.
        let bareHarness = makeCoordinator(candidate: candidate, rules: [rule])
        let bare = try await bareHarness.coordinator.execute(request(for: candidate, rule: rule))
        #expect(bare == .skipped("candidate is no longer eligible"))
        #expect(await bareHarness.fileAccess.moveCount() == 0)
    }

    @Test func testUnboundedFolderWalkDefersInsteadOfTrashing() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], walkResult: .indeterminate)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .deferred("folder is too large to verify before moving to Trash"))
        #expect(await harness.fileAccess.moveCount() == 0)
    }

    @Test func testHiddenProtectionIsRequestedFromWalkOnlyForNonDotCandidates() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], settings: AgentSettings(protectHiddenFiles: true))
        _ = try await harness.coordinator.execute(request(for: candidate, rule: rule))
        #expect(await harness.fileAccess.lastProtectHiddenFiles() == true)

        let off = makeCoordinator(candidate: candidate, rules: [rule])
        _ = try await off.coordinator.execute(request(for: candidate, rule: rule))
        #expect(await off.fileAccess.lastProtectHiddenFiles() == false)
    }

    @Test func testHiddenDescendantOfTrashedFolderBlocksMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], settings: AgentSettings(protectHiddenFiles: true), protectedDescendant: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .skipped("folder contains a protected descendant"))
    }

    @Test func testGlobalPauseAtExecutionTimeBlocksMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], globallyPaused: true)

        let outcome = try await harness.coordinator.execute(request(for: candidate, rule: rule))

        #expect(outcome == .deferred("pruning is paused"))
        let moves = await harness.fileAccess.moveCount()
        #expect(moves == 0)
    }

    @Test func testChangedDeadlineAndFutureDeadlineBlockMove() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active, lifetime: 200)
        let staleRequest = TrashRequest(candidateIdentity: candidate.identity, source: .rule(rule.id), scheduledAt: Date(timeIntervalSinceReferenceDate: 100))
        let staleHarness = makeCoordinator(candidate: candidate, rules: [rule])
        let staleOutcome = try await staleHarness.coordinator.execute(staleRequest)
        #expect(staleOutcome == .deferred("scheduled deadline changed; waiting for re-index"))
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

    @Test func successfulMoveRecordsReliableSizeOnlyOnSuccess() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], sizeMeasurer: { _ in
            ItemSizeMeasurement(bytes: 4096, items: 7, truncated: false)
        })
        _ = try await harness.coordinator.execute(request(for: candidate, rule: rule))
        let events = await harness.audit.events()
        #expect(events.first?.bytes == nil)
        #expect(events.first?.itemCount == nil)
        #expect(events.last?.bytes == 4096)
        #expect(events.last?.itemCount == 7)
        #expect(events.last?.detail == "/.Trash/node_modules")
    }

    @Test func unknownOrTruncatedSizesNeverBlockTrash() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let measurers: [@Sendable (String) async throws -> ItemSizeMeasurement?] = [
            { _ in nil },
            { _ in throw StubError.failed },
            { _ in ItemSizeMeasurement(bytes: 1024, items: 2, truncated: true) }
        ]
        for measurer in measurers {
            let harness = makeCoordinator(candidate: candidate, rules: [rule], sizeMeasurer: measurer)
            _ = try await harness.coordinator.execute(request(for: candidate, rule: rule))
            #expect(await harness.fileAccess.moveCount() == 1)
            let moved = try #require(await harness.audit.events().last)
            #expect(moved.kind == .movedToTrash)
            #expect(moved.bytes == nil)
            #expect(moved.itemCount == 1)
        }
    }

    @Test func failedTrashDoesNotRecordMeasuredSize() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let harness = makeCoordinator(candidate: candidate, rules: [rule], trashError: StubError.failed, sizeMeasurer: { _ in
            ItemSizeMeasurement(bytes: 4096, items: 7, truncated: false)
        })
        await #expect(throws: TrashExecutionError.self) {
            try await harness.coordinator.execute(request(for: candidate, rule: rule))
        }
        let events = await harness.audit.events()
        #expect(events.map(\.kind) == [.trashAttempted, .trashFailed])
        #expect(events.allSatisfy { $0.bytes == nil && $0.itemCount == nil })
    }

    @Test func measurementRunsAfterFinalPreflightAndNotForPreview() async throws {
        let candidate = makeCandidate()
        let rule = try makeRule(state: .active)
        let access = MockTrashFileAccess(candidate: candidate, walkResult: .none, symlinkAncestor: false, trashError: nil)
        let coordinator = TrashCoordinator(
            policyStore: MockPolicyStore(snapshot: PolicySnapshot(rules: [rule], overrides: [], managedRoots: [try makeRoot()], globallyPaused: false)),
            fileAccess: access, audit: MockAudit(), clock: FixedClock(Date(timeIntervalSinceReferenceDate: 1_000)),
            sizeMeasurer: { path in
                #expect(path == candidate.identity.pathHint)
                #expect(await access.eventLog() == ["inspect", "inspect"])
                return nil
            }
        )
        _ = try await coordinator.execute(request(for: candidate, rule: rule))
        let preview = try makeRule(state: .preview)
        let harness = makeCoordinator(candidate: candidate, rules: [preview], sizeMeasurer: { _ in
            Issue.record("Preview must not measure ledger sizes")
            return nil
        })
        _ = try await harness.coordinator.execute(request(for: candidate, rule: preview))
    }

    @Test func legacyAuditDecodesWithUnknownSize() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","occurredAt":0,"kind":"movedToTrash","detail":"/.Trash/old"}"#.utf8)
        let event = try JSONDecoder().decode(TrashAuditEvent.self, from: data)
        #expect(event.bytes == nil)
        #expect(event.itemCount == nil)
        #expect(event.detail == "/.Trash/old")
    }

    private func makeRoot() throws -> ManagedRoot {
        try ManagedRoot(displayName: "Developer", path: "/Developer", bookmarkData: Data([1]))
    }

    private func makeCoordinator(
        candidate: RuleCandidate,
        rules: [LifetimeRule],
        overrides: [ItemPolicyOverride] = [],
        managedRoots: [ManagedRoot]? = nil,
        globallyPaused: Bool = false,
        settings: AgentSettings = .default,
        protectedDescendant: Bool = false,
        walkResult: DescendantProtection? = nil,
        symlinkAncestor: Bool = false,
        hydrated: RuleCandidate? = nil,
        trashError: Error? = nil,
        now: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        sizeMeasurer: @escaping @Sendable (String) async throws -> ItemSizeMeasurement? = { _ in nil }
    ) -> (coordinator: TrashCoordinator, fileAccess: MockTrashFileAccess, audit: MockAudit) {
        let fileAccess = MockTrashFileAccess(
            candidate: candidate,
            walkResult: walkResult ?? (protectedDescendant ? .protected : DescendantProtection.none),
            symlinkAncestor: symlinkAncestor,
            trashError: trashError
        )
        let audit = MockAudit()
        let roots = managedRoots ?? [try! makeRoot()]
        let coordinator = TrashCoordinator(
            policyStore: MockPolicyStore(snapshot: PolicySnapshot(rules: rules, overrides: overrides, managedRoots: roots, globallyPaused: globallyPaused, settings: settings)),
            fileAccess: fileAccess,
            audit: audit,
            clock: FixedClock(now),
            candidateHydrator: hydrated.map { StubHydrator(result: $0) },
            sizeMeasurer: sizeMeasurer
        )
        return (coordinator, fileAccess, audit)
    }

    private func makeRule(state: RuleState, lifetime: TimeInterval = 100, basis: ExpiryBasis = .modified) throws -> LifetimeRule {
        try LifetimeRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "Old Node Modules",
            scope: try RuleScope(path: "/Developer", recursive: true),
            matcher: try ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
            expiryBasis: basis,
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

private struct StubHydrator: CandidateHydrating {
    let result: RuleCandidate
    func hydrate(_ candidate: RuleCandidate, rules: [LifetimeRule], now: Date) async throws -> RuleCandidate { result }
}

private actor SequencedPolicyStore: PolicySnapshotProviding {
    private var snapshots: [PolicySnapshot]
    init(snapshots: [PolicySnapshot]) { self.snapshots = snapshots }
    func loadSnapshot() async throws -> PolicySnapshot {
        snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
}

private actor MockTrashFileAccess: TrashFileAccess {
    let candidate: RuleCandidate
    let walkResult: DescendantProtection
    let symlinkAncestor: Bool
    let trashError: Error?
    private(set) var moves = 0
    private var log: [String] = []
    private var protectHidden: Bool?

    init(candidate: RuleCandidate, walkResult: DescendantProtection, symlinkAncestor: Bool, trashError: Error?) {
        self.candidate = candidate
        self.walkResult = walkResult
        self.symlinkAncestor = symlinkAncestor
        self.trashError = trashError
    }

    func inspect(path: String) async throws -> RuleCandidate? {
        log.append("inspect")
        return candidate
    }
    func hasSymbolicLinkAncestor(of path: String, below rootPath: String) async throws -> Bool { symlinkAncestor }
    func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride], protectHiddenFiles: Bool, budget: DescendantWalkBudget) async throws -> DescendantProtection {
        protectHidden = protectHiddenFiles
        return walkResult
    }
    func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String {
        moves += 1
        log.append("move")
        if let trashError { throw trashError }
        return "/.Trash/\(URL(fileURLWithPath: path).lastPathComponent)"
    }
    func moveCount() -> Int { moves }
    func eventLog() -> [String] { log }
    func lastProtectHiddenFiles() -> Bool? { protectHidden }
}

private actor MockAudit: TrashAuditRecording {
    private(set) var recorded: [TrashAuditEvent] = []
    func append(_ event: TrashAuditEvent) async throws { recorded.append(event) }
    func events() -> [TrashAuditEvent] { recorded }
}
