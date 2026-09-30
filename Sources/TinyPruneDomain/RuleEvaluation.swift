import Foundation

public struct FilesystemIdentity: Hashable, Codable, Sendable {
    public let volumeIdentifier: UUID
    public let resourceIdentifier: Data
    public let pathHint: String

    public init(volumeIdentifier: UUID, resourceIdentifier: Data, pathHint: String) {
        self.volumeIdentifier = volumeIdentifier
        self.resourceIdentifier = resourceIdentifier
        self.pathHint = pathHint
    }
}

public struct CandidateTimestamps: Hashable, Codable, Sendable {
    public let created: Date?
    public let modified: Date?
    public let firstObserved: Date?
    public let observedActivity: Date?
    public let accessed: Date?
    public let projectActivity: Date?
    public let explicitDate: Date?

    public init(
        created: Date? = nil,
        modified: Date? = nil,
        firstObserved: Date? = nil,
        observedActivity: Date? = nil,
        accessed: Date? = nil,
        projectActivity: Date? = nil,
        explicitDate: Date? = nil
    ) {
        self.created = created
        self.modified = modified
        self.firstObserved = firstObserved
        self.observedActivity = observedActivity
        self.accessed = accessed
        self.projectActivity = projectActivity
        self.explicitDate = explicitDate
    }

    public func value(for basis: ExpiryBasis) -> Date? {
        switch basis {
        case .created: created
        case .modified: modified
        case .firstObserved: firstObserved
        case .observedActivity: observedActivity
        case .accessed: accessed
        case .projectActivity: projectActivity
        case .explicitDate: explicitDate
        }
    }
}

public struct RuleCandidate: Hashable, Codable, Sendable {
    public let identity: FilesystemIdentity
    public let name: String
    public let kind: ItemKind
    public let timestamps: CandidateTimestamps

    public init(identity: FilesystemIdentity, name: String, kind: ItemKind, timestamps: CandidateTimestamps) {
        self.identity = identity
        self.name = name
        self.kind = kind
        self.timestamps = timestamps
    }
}

public enum EvaluationSuppression: String, Codable, Sendable {
    case itemDoesNotMatch
    case missingExpiryTimestamp
    case pausedRule
}

public enum ScheduledDisposition: String, Codable, Sendable {
    case preview
    case active
}

public struct CandidateExplanation: Hashable, Codable, Sendable {
    public let candidateIdentity: FilesystemIdentity
    public let matchedRuleID: UUID
    public let matchedRuleName: String
    public let expiryBasis: ExpiryBasis
    public let basisDate: Date
    public let eligibleAt: Date
    public let scheduledAt: Date
    public let disposition: ScheduledDisposition

    public init(candidate: RuleCandidate, rule: LifetimeRule, basisDate: Date, eligibleAt: Date, scheduledAt: Date, disposition: ScheduledDisposition) {
        self.candidateIdentity = candidate.identity
        self.matchedRuleID = rule.id
        self.matchedRuleName = rule.name
        self.expiryBasis = rule.expiryBasis
        self.basisDate = basisDate
        self.eligibleAt = eligibleAt
        self.scheduledAt = scheduledAt
        self.disposition = disposition
    }
}

public enum CandidateEvaluation: Hashable, Codable, Sendable {
    case scheduled(CandidateExplanation)
    case suppressed(EvaluationSuppression)
}

public enum RuleEvaluator {
    public static func evaluate(candidate: RuleCandidate, against rule: LifetimeRule) -> CandidateEvaluation {
        guard rule.matcher.matches(name: candidate.name, kind: candidate.kind) else {
            return .suppressed(.itemDoesNotMatch)
        }
        guard rule.state != .paused else {
            return .suppressed(.pausedRule)
        }
        guard let basisDate = candidate.timestamps.value(for: rule.expiryBasis) else {
            return .suppressed(.missingExpiryTimestamp)
        }

        let eligibleAt = basisDate.addingTimeInterval(rule.lifetime.seconds)
        let scheduledAt = eligibleAt.addingTimeInterval(rule.gracePeriod?.seconds ?? 0)
        let disposition: ScheduledDisposition = rule.state == .preview ? .preview : .active
        return .scheduled(CandidateExplanation(
            candidate: candidate,
            rule: rule,
            basisDate: basisDate,
            eligibleAt: eligibleAt,
            scheduledAt: scheduledAt,
            disposition: disposition
        ))
    }
}
