import Foundation
import TinyPruneDomain
import TinyPruneIPC

public struct PolicySnapshot: Sendable {
    public let rules: [LifetimeRule]
    public let overrides: [ItemPolicyOverride]
    public let managedRoots: [ManagedRoot]
    /// Effective pause state: already `false` once `pausedUntil` has passed (resolved at read time).
    public let globallyPaused: Bool
    public let pausedUntil: Date?
    public let settings: AgentSettings
    /// Monotonic policy revision maintained by the store; every policy mutation bumps it. Clients echo it back
    /// when replacing policy so a stale snapshot cannot silently overwrite newer changes.
    public var revision: Int

    public init(
        rules: [LifetimeRule],
        overrides: [ItemPolicyOverride],
        managedRoots: [ManagedRoot] = [],
        globallyPaused: Bool,
        pausedUntil: Date? = nil,
        settings: AgentSettings = .default,
        revision: Int = 0
    ) {
        self.rules = rules
        self.overrides = overrides
        self.managedRoots = managedRoots
        self.globallyPaused = globallyPaused
        self.pausedUntil = pausedUntil
        self.settings = settings
        self.revision = revision
    }
}

public protocol PolicySnapshotProviding: Sendable {
    func loadSnapshot() async throws -> PolicySnapshot
}

/// Overlays persisted activity (first observed, observed activity, project activity) on a filesystem candidate so
/// that execution-time evaluation uses exactly the timestamps the indexer used when it scheduled the deadline.
public protocol CandidateHydrating: Sendable {
    func hydrate(_ candidate: RuleCandidate, rules: [LifetimeRule], now: Date) async throws -> RuleCandidate
}

/// Bounds a descendant walk by entry count and by wall time measured on the injected clock.
public struct DescendantWalkBudget: Sendable {
    public let maxEntries: Int
    public let deadline: Date
    public let clock: any SafetyClock

    public init(maxEntries: Int, deadline: Date, clock: any SafetyClock) {
        self.maxEntries = maxEntries
        self.deadline = deadline
        self.clock = clock
    }
}

public struct DescendantWalkLimits: Equatable, Sendable {
    public var maxEntries: Int
    public var maxDuration: TimeInterval

    public init(maxEntries: Int = 250_000, maxDuration: TimeInterval = 10) {
        self.maxEntries = maxEntries
        self.maxDuration = maxDuration
    }
}

public enum DescendantProtection: Equatable, Sendable {
    case none
    case protected
    /// The walk hit its entry or time budget before it could prove the folder is free of protected content.
    case indeterminate
}

public protocol TrashFileAccess: Sendable {
    func inspect(path: String) async throws -> RuleCandidate?
    /// True when any directory between `rootPath` (exclusive) and `path` (exclusive) is a symbolic link.
    func hasSymbolicLinkAncestor(of path: String, below rootPath: String) async throws -> Bool
    func hasProtectedDescendant(
        path: String,
        overrides: [ItemPolicyOverride],
        protectHiddenFiles: Bool,
        budget: DescendantWalkBudget
    ) async throws -> DescendantProtection
    func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String
}

public protocol SafetyClock: Sendable {
    func now() -> Date
}

public struct SystemSafetyClock: SafetyClock {
    public init() {}
    public func now() -> Date { Date() }
}

public enum ScheduledSource: Hashable, Codable, Sendable {
    case rule(UUID)
    case customOverride(UUID)
}

public struct TrashRequest: Hashable, Codable, Sendable {
    public let candidateIdentity: FilesystemIdentity
    public let source: ScheduledSource
    public let scheduledAt: Date

    public init(candidateIdentity: FilesystemIdentity, source: ScheduledSource, scheduledAt: Date) {
        self.candidateIdentity = candidateIdentity
        self.source = source
        self.scheduledAt = scheduledAt
    }
}

public enum TrashAuditKind: String, Codable, Sendable {
    case policyReplaced
    case ruleCreated
    case ruleEdited
    case rulePaused
    case ruleDeleted
    case itemProtected
    case itemUnprotected
    case expiryChanged
    case globalPauseChanged
    case previewSkipped
    case notDue
    case safetySkipped
    case trashAttempted
    case movedToTrash
    case trashFailed
    case settingsChanged
}

public struct TrashAuditEvent: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let kind: TrashAuditKind
    public let identity: FilesystemIdentity?
    public let ruleID: UUID?
    public let detail: String?

    public init(id: UUID = UUID(), occurredAt: Date, kind: TrashAuditKind, identity: FilesystemIdentity? = nil, ruleID: UUID? = nil, detail: String? = nil) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.identity = identity
        self.ruleID = ruleID
        self.detail = detail
    }
}

public protocol TrashAuditRecording: Sendable {
    func append(_ event: TrashAuditEvent) async throws
}

public enum TrashExecutionOutcome: Hashable, Codable, Sendable {
    case previewed
    case notDue(Date)
    /// Terminal: the candidate must not be trashed under this deadline (missing, replaced, protected, unsupported...).
    case skipped(String)
    /// Not terminal: the deadline must be kept and retried later (pause, paused rule, moved deadline, too large to verify).
    case deferred(String)
    case movedToTrash(originalPath: String, trashedPath: String)
}

public enum TrashExecutionError: Error, Equatable, Sendable {
    case policyReadFailed(String)
    case filesystemReadFailed(String)
    case auditWriteFailed(String)
    case filesystemOperationFailed(String)
    case movedButAuditFailed(path: String, detail: String)
    case updateInstallationPending
}

private struct TrashAuthorization {
    let deadline: Date
    let disposition: ScheduledDisposition
    let rule: LifetimeRule?
}

private func authorization(for source: ScheduledSource, resolution: RuleResolution, snapshot: PolicySnapshot) -> TrashAuthorization? {
    switch (source, resolution) {
    case let (.rule(ruleID), .scheduled(explanation)) where explanation.matchedRuleID == ruleID:
        guard let rule = snapshot.rules.first(where: { $0.id == ruleID }) else { return nil }
        return TrashAuthorization(deadline: explanation.scheduledAt, disposition: explanation.disposition, rule: rule)
    case let (.customOverride(overrideID), .customExpiry(explanation)) where explanation.overrideID == overrideID:
        return TrashAuthorization(deadline: explanation.expiresAt, disposition: explanation.disposition, rule: nil)
    default:
        return nil
    }
}

private struct ClearedCandidate {
    let candidate: RuleCandidate
    let authorization: TrashAuthorization
}

private enum Preflight {
    case cleared(ClearedCandidate)
    case finished(TrashExecutionOutcome)
}

public actor TrashCoordinator {
    private let policyStore: any PolicySnapshotProviding
    private let fileAccess: any TrashFileAccess
    private let audit: any TrashAuditRecording
    private let clock: any SafetyClock
    private let updateGate: UpdateInstallationGate
    private let hydrator: (any CandidateHydrating)?
    private let walkLimits: DescendantWalkLimits

    /// - Parameter candidateHydrator: overlays persisted activity on freshly inspected candidates. Defaults to the
    ///   policy store itself when it can hydrate (the SQLite store does), so execution-time evaluation sees the same
    ///   timestamps as the indexer that scheduled the deadline.
    public init(
        policyStore: any PolicySnapshotProviding,
        fileAccess: any TrashFileAccess,
        audit: any TrashAuditRecording,
        clock: any SafetyClock = SystemSafetyClock(),
        updateGate: UpdateInstallationGate = UpdateInstallationGate(),
        candidateHydrator: (any CandidateHydrating)? = nil,
        descendantWalkLimits: DescendantWalkLimits = DescendantWalkLimits()
    ) {
        self.policyStore = policyStore
        self.fileAccess = fileAccess
        self.audit = audit
        self.clock = clock
        self.updateGate = updateGate
        self.hydrator = candidateHydrator ?? (policyStore as? any CandidateHydrating)
        self.walkLimits = descendantWalkLimits
    }

    public nonisolated func observeUpdateGateChanges(_ onChange: @escaping @Sendable () -> Void) throws -> UpdateInstallationObservation {
        try updateGate.observeChanges(onChange)
    }

    public func execute(_ request: TrashRequest) async throws -> TrashExecutionOutcome {
        let path = RuleScope.normalized(request.candidateIdentity.pathHint)
        let updatePermit: UpdateTrashPermit?
        do {
            updatePermit = try updateGate.acquireTrashPermit()
        } catch {
            throw TrashExecutionError.policyReadFailed("update installation gate: \(error)")
        }
        guard let updatePermit else {
            _ = try await recordSkip("app update installation is pending", request: request, at: clock.now())
            // A transient installation block is not terminal: the scheduler must retain this deadline.
            throw TrashExecutionError.updateInstallationPending
        }
        // ARC may otherwise release the permit before an awaited filesystem operation completes.
        defer { withExtendedLifetime(updatePermit) {} }

        // Order: path/root/ancestor checks -> inspect + hydrate -> bounded descendant walk -> reload policy ->
        // final inspect + hydrate -> audit the attempt -> move (identity re-verified under file coordination).
        let snapshot = try await loadSnapshot()
        let initial: ClearedCandidate
        switch try await preflight(request, path: path, snapshot: snapshot) {
        case .finished(let outcome): return outcome
        case .cleared(let cleared): initial = cleared
        }
        if initial.candidate.kind == .directory,
           let blocked = try await descendantOutcome(for: initial, request: request, path: path, snapshot: snapshot) {
            return blocked
        }

        let finalSnapshot = try await loadSnapshot()
        let confirmed: ClearedCandidate
        switch try await preflight(request, path: path, snapshot: finalSnapshot) {
        case .finished(let outcome): return outcome
        case .cleared(let cleared): confirmed = cleared
        }
        guard confirmed.authorization.deadline == initial.authorization.deadline,
              confirmed.authorization.rule == initial.authorization.rule else {
            return .deferred("policy or deadline changed while preparing to move")
        }
        if confirmed.candidate.kind == .directory,
           finalSnapshot.overrides != snapshot.overrides || finalSnapshot.settings.protectHiddenFiles != snapshot.settings.protectHiddenFiles,
           let blocked = try await descendantOutcome(for: confirmed, request: request, path: path, snapshot: finalSnapshot) {
            return blocked
        }

        let ruleID = confirmed.authorization.rule?.id
        try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .trashAttempted, identity: request.candidateIdentity, ruleID: ruleID))
        let trashedPath: String
        do {
            trashedPath = try await fileAccess.moveToTrash(path: path, expectedIdentity: request.candidateIdentity)
        } catch {
            do {
                try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .trashFailed, identity: request.candidateIdentity, ruleID: ruleID, detail: String(describing: error)))
            } catch {
                throw TrashExecutionError.auditWriteFailed("Trash failed and failure audit could not be written: \(error)")
            }
            throw TrashExecutionError.filesystemOperationFailed(String(describing: error))
        }

        do {
            try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .movedToTrash, identity: request.candidateIdentity, ruleID: ruleID, detail: trashedPath))
        } catch {
            throw TrashExecutionError.movedButAuditFailed(path: trashedPath, detail: String(describing: error))
        }
        return .movedToTrash(originalPath: path, trashedPath: trashedPath)
    }

    /// One complete eligibility decision against a given policy snapshot and the current filesystem state.
    private func preflight(_ request: TrashRequest, path: String, snapshot: PolicySnapshot) async throws -> Preflight {
        if snapshot.globallyPaused { return .finished(.deferred("pruning is paused")) }
        switch request.source {
        case .rule(let ruleID):
            guard let rule = snapshot.rules.first(where: { $0.id == ruleID }) else {
                return .finished(try await recordSkip("rule no longer exists", request: request, at: clock.now()))
            }
            if rule.state == .paused { return .finished(.deferred("rule is paused")) }
        case .customOverride(let overrideID):
            guard let override = snapshot.overrides.first(where: { $0.id == overrideID }) else {
                return .finished(try await recordSkip("custom expiry no longer exists", request: request, at: clock.now()))
            }
            if case .customExpiry(_, let state) = override.policy, state == .paused {
                return .finished(.deferred("custom expiry is paused"))
            }
        }

        guard let root = snapshot.managedRoots.first(where: { path.hasPrefix(RuleScope.normalized($0.path) + "/") }) else {
            return .finished(try await recordSkip("item is outside every managed root", request: request, at: clock.now()))
        }
        do {
            if try await fileAccess.hasSymbolicLinkAncestor(of: path, below: RuleScope.normalized(root.path)) {
                return .finished(try await recordSkip("item is reached through a symbolic link", request: request, at: clock.now()))
            }
        } catch {
            throw TrashExecutionError.filesystemReadFailed(String(describing: error))
        }

        let candidate: RuleCandidate
        do {
            guard let observed = try await fileAccess.inspect(path: path) else {
                return .finished(try await recordSkip("candidate is unavailable", request: request, at: clock.now()))
            }
            candidate = observed
        } catch {
            throw TrashExecutionError.filesystemReadFailed(String(describing: error))
        }
        guard candidate.identity == request.candidateIdentity else {
            return .finished(try await recordSkip("filesystem identity changed", request: request, at: clock.now()))
        }
        let evaluated: RuleCandidate
        do {
            evaluated = try await hydrator?.hydrate(candidate, rules: snapshot.rules, now: clock.now()) ?? candidate
        } catch {
            throw TrashExecutionError.policyReadFailed("candidate activity: \(error)")
        }

        let resolution = RuleResolver.resolve(
            candidate: evaluated,
            rules: snapshot.rules,
            overrides: snapshot.overrides,
            globallyPaused: snapshot.globallyPaused,
            settings: snapshot.settings
        )
        guard let authorization = authorization(for: request.source, resolution: resolution, snapshot: snapshot) else {
            let reason: String
            if case .protected = resolution { reason = "item is protected by Keep" } else { reason = "candidate is no longer eligible" }
            return .finished(try await recordSkip(reason, request: request, at: clock.now()))
        }
        if authorization.disposition == .preview {
            try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .previewSkipped, identity: request.candidateIdentity, ruleID: authorization.rule?.id))
            return .finished(.previewed)
        }
        guard authorization.deadline == request.scheduledAt else {
            return .finished(.deferred("scheduled deadline changed; waiting for re-index"))
        }
        let now = clock.now()
        guard now >= authorization.deadline else {
            try await append(TrashAuditEvent(occurredAt: now, kind: .notDue, identity: request.candidateIdentity, ruleID: authorization.rule?.id))
            return .finished(.notDue(authorization.deadline))
        }
        guard authorization.rule?.action == .trashItem || authorization.rule == nil else {
            return .finished(try await recordSkip("folder action requires a dedicated executor", request: request, at: now, ruleID: authorization.rule?.id))
        }
        return .cleared(ClearedCandidate(candidate: evaluated, authorization: authorization))
    }

    /// Returns a terminal/deferred outcome when the folder must not be trashed whole, `nil` when it is clear.
    private func descendantOutcome(
        for cleared: ClearedCandidate,
        request: TrashRequest,
        path: String,
        snapshot: PolicySnapshot
    ) async throws -> TrashExecutionOutcome? {
        let started = clock.now()
        let budget = DescendantWalkBudget(
            maxEntries: walkLimits.maxEntries,
            deadline: started.addingTimeInterval(walkLimits.maxDuration),
            clock: clock
        )
        // A dot-named candidate can only reach this point through a rule that targets dot items explicitly.
        let protectHidden = snapshot.settings.protectHiddenFiles && !cleared.candidate.name.hasPrefix(".")
        let status: DescendantProtection
        do {
            status = try await fileAccess.hasProtectedDescendant(
                path: path,
                overrides: snapshot.overrides,
                protectHiddenFiles: protectHidden,
                budget: budget
            )
        } catch {
            throw TrashExecutionError.filesystemReadFailed(String(describing: error))
        }
        switch status {
        case .none: return nil
        case .protected:
            return try await recordSkip("folder contains a protected descendant", request: request, at: clock.now(), ruleID: cleared.authorization.rule?.id)
        case .indeterminate:
            return .deferred("folder is too large to verify before moving to Trash")
        }
    }

    private func loadSnapshot() async throws -> PolicySnapshot {
        do {
            return try await policyStore.loadSnapshot()
        } catch {
            throw TrashExecutionError.policyReadFailed(String(describing: error))
        }
    }

    private func recordSkip(_ reason: String, request: TrashRequest, at date: Date, ruleID: UUID? = nil) async throws -> TrashExecutionOutcome {
        try await append(TrashAuditEvent(occurredAt: date, kind: .safetySkipped, identity: request.candidateIdentity, ruleID: ruleID, detail: reason))
        return .skipped(reason)
    }

    private func append(_ event: TrashAuditEvent) async throws {
        do {
            try await audit.append(event)
        } catch {
            throw TrashExecutionError.auditWriteFailed(String(describing: error))
        }
    }
}
