import Foundation
import TinyPruneDomain

public struct PolicySnapshot: Sendable {
    public let rules: [LifetimeRule]
    public let overrides: [ItemPolicyOverride]
    public let managedRoots: [ManagedRoot]
    public let globallyPaused: Bool

    public init(rules: [LifetimeRule], overrides: [ItemPolicyOverride], managedRoots: [ManagedRoot] = [], globallyPaused: Bool) {
        self.rules = rules
        self.overrides = overrides
        self.managedRoots = managedRoots
        self.globallyPaused = globallyPaused
    }
}

public protocol PolicySnapshotProviding: Sendable {
    func loadSnapshot() async throws -> PolicySnapshot
}

public protocol TrashFileAccess: Sendable {
    func inspect(path: String) async throws -> RuleCandidate?
    func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride]) async throws -> Bool
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
    case previewSkipped
    case notDue
    case safetySkipped
    case trashAttempted
    case movedToTrash
    case trashFailed
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
    case skipped(String)
    case movedToTrash(originalPath: String, trashedPath: String)
}

public enum TrashExecutionError: Error, Equatable, Sendable {
    case policyReadFailed(String)
    case filesystemReadFailed(String)
    case auditWriteFailed(String)
    case filesystemOperationFailed(String)
    case movedButAuditFailed(path: String, detail: String)
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

public actor TrashCoordinator {
    private let policyStore: any PolicySnapshotProviding
    private let fileAccess: any TrashFileAccess
    private let audit: any TrashAuditRecording
    private let clock: any SafetyClock

    public init(
        policyStore: any PolicySnapshotProviding,
        fileAccess: any TrashFileAccess,
        audit: any TrashAuditRecording,
        clock: any SafetyClock = SystemSafetyClock()
    ) {
        self.policyStore = policyStore
        self.fileAccess = fileAccess
        self.audit = audit
        self.clock = clock
    }

    public func execute(_ request: TrashRequest) async throws -> TrashExecutionOutcome {
        let path = request.candidateIdentity.pathHint
        let now = clock.now()
        let snapshot: PolicySnapshot
        do {
            snapshot = try await policyStore.loadSnapshot()
        } catch {
            throw TrashExecutionError.policyReadFailed(String(describing: error))
        }

        let currentCandidate: RuleCandidate
        do {
            guard let observed = try await fileAccess.inspect(path: path) else {
                return try await recordSkip("candidate is unavailable", request: request, at: now)
            }
            currentCandidate = observed
        } catch {
            throw TrashExecutionError.filesystemReadFailed(String(describing: error))
        }
        guard currentCandidate.identity == request.candidateIdentity else {
            return try await recordSkip("filesystem identity changed", request: request, at: now)
        }

        let resolution = RuleResolver.resolve(
            candidate: currentCandidate,
            rules: snapshot.rules,
            overrides: snapshot.overrides,
            globallyPaused: snapshot.globallyPaused
        )
        guard let initialAuthorization = authorization(for: request.source, resolution: resolution, snapshot: snapshot) else {
            return try await recordSkip("candidate is no longer eligible", request: request, at: now)
        }
        if initialAuthorization.disposition == .preview {
            try await append(TrashAuditEvent(occurredAt: now, kind: .previewSkipped, identity: request.candidateIdentity, ruleID: initialAuthorization.rule?.id))
            return .previewed
        }

        let applicableRule = initialAuthorization.rule
        let currentDeadline = initialAuthorization.deadline
        guard currentDeadline == request.scheduledAt else {
            return try await recordSkip("scheduled deadline changed", request: request, at: now, ruleID: applicableRule?.id)
        }
        guard now >= currentDeadline else {
            try await append(TrashAuditEvent(occurredAt: now, kind: .notDue, identity: request.candidateIdentity, ruleID: applicableRule?.id))
            return .notDue(currentDeadline)
        }
        guard applicableRule?.action == .trashItem || applicableRule == nil else {
            return try await recordSkip("folder action requires a dedicated executor", request: request, at: now, ruleID: applicableRule?.id)
        }

        let finalSnapshot: PolicySnapshot
        do {
            finalSnapshot = try await policyStore.loadSnapshot()
        } catch {
            throw TrashExecutionError.policyReadFailed(String(describing: error))
        }
        let finalCandidate: RuleCandidate
        do {
            guard let observed = try await fileAccess.inspect(path: path) else {
                return try await recordSkip("candidate is unavailable", request: request, at: clock.now(), ruleID: applicableRule?.id)
            }
            finalCandidate = observed
        } catch {
            throw TrashExecutionError.filesystemReadFailed(String(describing: error))
        }
        guard finalCandidate.identity == request.candidateIdentity else {
            return try await recordSkip("filesystem identity changed", request: request, at: clock.now(), ruleID: applicableRule?.id)
        }
        let finalResolution = RuleResolver.resolve(
            candidate: finalCandidate,
            rules: finalSnapshot.rules,
            overrides: finalSnapshot.overrides,
            globallyPaused: finalSnapshot.globallyPaused
        )
        guard let finalAuthorization = authorization(for: request.source, resolution: finalResolution, snapshot: finalSnapshot) else {
            return try await recordSkip("current policy no longer authorizes this move", request: request, at: clock.now(), ruleID: applicableRule?.id)
        }
        if finalAuthorization.disposition == .preview {
            try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .previewSkipped, identity: request.candidateIdentity, ruleID: finalAuthorization.rule?.id))
            return .previewed
        }
        guard finalAuthorization.deadline == request.scheduledAt,
              finalAuthorization.rule == applicableRule,
              finalAuthorization.rule?.action == .trashItem || finalAuthorization.rule == nil else {
            return try await recordSkip("current policy or deadline changed", request: request, at: clock.now(), ruleID: applicableRule?.id)
        }
        let finalNow = clock.now()
        guard finalNow >= finalAuthorization.deadline else {
            try await append(TrashAuditEvent(occurredAt: finalNow, kind: .notDue, identity: request.candidateIdentity, ruleID: applicableRule?.id))
            return .notDue(finalAuthorization.deadline)
        }
        if finalCandidate.kind == .directory {
            do {
                if try await fileAccess.hasProtectedDescendant(path: path, overrides: finalSnapshot.overrides) {
                    return try await recordSkip("folder contains a protected descendant", request: request, at: clock.now(), ruleID: applicableRule?.id)
                }
            } catch {
                throw TrashExecutionError.filesystemReadFailed(String(describing: error))
            }
        }

        try await append(TrashAuditEvent(occurredAt: finalNow, kind: .trashAttempted, identity: request.candidateIdentity, ruleID: applicableRule?.id))
        let committedSnapshot: PolicySnapshot
        do {
            committedSnapshot = try await policyStore.loadSnapshot()
        } catch {
            throw TrashExecutionError.policyReadFailed(String(describing: error))
        }
        let committedCandidate: RuleCandidate
        do {
            guard let observed = try await fileAccess.inspect(path: path) else {
                return try await recordSkip("candidate is unavailable", request: request, at: clock.now(), ruleID: applicableRule?.id)
            }
            committedCandidate = observed
        } catch {
            throw TrashExecutionError.filesystemReadFailed(String(describing: error))
        }
        guard committedCandidate.identity == request.candidateIdentity else {
            return try await recordSkip("filesystem identity changed", request: request, at: clock.now(), ruleID: applicableRule?.id)
        }
        let committedResolution = RuleResolver.resolve(
            candidate: committedCandidate,
            rules: committedSnapshot.rules,
            overrides: committedSnapshot.overrides,
            globallyPaused: committedSnapshot.globallyPaused
        )
        guard let committedAuthorization = authorization(for: request.source, resolution: committedResolution, snapshot: committedSnapshot),
              committedAuthorization.disposition == .active,
              committedAuthorization.deadline == request.scheduledAt,
              committedAuthorization.rule == applicableRule,
              clock.now() >= committedAuthorization.deadline else {
            return try await recordSkip("policy changed at the Trash boundary", request: request, at: clock.now(), ruleID: applicableRule?.id)
        }
        if committedCandidate.kind == .directory {
            do {
                if try await fileAccess.hasProtectedDescendant(path: path, overrides: committedSnapshot.overrides) {
                    return try await recordSkip("folder contains a protected descendant", request: request, at: clock.now(), ruleID: applicableRule?.id)
                }
            } catch {
                throw TrashExecutionError.filesystemReadFailed(String(describing: error))
            }
        }
        let trashedPath: String
        do {
            trashedPath = try await fileAccess.moveToTrash(path: path, expectedIdentity: request.candidateIdentity)
        } catch {
            do {
                try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .trashFailed, identity: request.candidateIdentity, ruleID: applicableRule?.id, detail: String(describing: error)))
            } catch {
                throw TrashExecutionError.auditWriteFailed("Trash failed and failure audit could not be written: \(error)")
            }
            throw TrashExecutionError.filesystemOperationFailed(String(describing: error))
        }

        do {
            try await append(TrashAuditEvent(occurredAt: clock.now(), kind: .movedToTrash, identity: request.candidateIdentity, ruleID: applicableRule?.id, detail: trashedPath))
        } catch {
            throw TrashExecutionError.movedButAuditFailed(path: trashedPath, detail: String(describing: error))
        }
        return .movedToTrash(originalPath: path, trashedPath: trashedPath)
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
