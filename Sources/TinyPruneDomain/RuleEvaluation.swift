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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.volumeIdentifier == rhs.volumeIdentifier && lhs.resourceIdentifier == rhs.resourceIdentifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(volumeIdentifier)
        hasher.combine(resourceIdentifier)
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
    case globalPause
    case previewOnly
    case hiddenProtected
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
    /// Set for an explicit item expiry rather than an inherited lifetime rule.
    public let customOverrideID: UUID?

    public init(customExpiry: CustomExpiryExplanation) {
        candidateIdentity = customExpiry.candidateIdentity
        matchedRuleID = customExpiry.overrideID
        matchedRuleName = "Custom expiry"
        expiryBasis = .explicitDate
        basisDate = customExpiry.expiresAt
        eligibleAt = customExpiry.expiresAt
        scheduledAt = customExpiry.expiresAt
        disposition = customExpiry.disposition
        customOverrideID = customExpiry.overrideID
    }

    public init(candidate: RuleCandidate, rule: LifetimeRule, basisDate: Date, eligibleAt: Date, scheduledAt: Date, disposition: ScheduledDisposition) {
        self.candidateIdentity = candidate.identity
        self.matchedRuleID = rule.id
        self.matchedRuleName = rule.name
        self.expiryBasis = rule.expiryBasis
        self.basisDate = basisDate
        self.eligibleAt = eligibleAt
        self.scheduledAt = scheduledAt
        self.disposition = disposition
        self.customOverrideID = nil
    }
}

public enum CandidateEvaluation: Hashable, Codable, Sendable {
    case scheduled(CandidateExplanation)
    case suppressed(EvaluationSuppression)
}

public enum RuleEvaluator {
    public static func evaluate(candidate: RuleCandidate, against rule: LifetimeRule, settings: AgentSettings = .default) -> CandidateEvaluation {
        guard rule.state != .paused else { return .suppressed(.pausedRule) }
        let path = RuleScope.normalized(candidate.identity.pathHint)
        let matches: Bool
        switch rule.matchMode {
        case .itemSpecific, .exactPath:
            matches = path == rule.scope.path && rule.matcher.matches(name: candidate.name, relativePath: candidate.name, kind: candidate.kind)
        case .scoped:
            matches = rule.scope.relativePath(of: path).map { rule.matcher.matches(name: candidate.name, relativePath: $0, kind: candidate.kind) } ?? false
        case .template:
            matches = rule.matcher.matches(name: candidate.name, relativePath: candidate.name, kind: candidate.kind)
        }
        guard matches else { return .suppressed(.itemDoesNotMatch) }
        if settings.protectHiddenFiles, isHiddenProtected(path: path, candidate: candidate, rule: rule) {
            return .suppressed(.hiddenProtected)
        }
        guard let basisDate = candidate.timestamps.value(for: rule.expiryBasis) else {
            return .suppressed(.missingExpiryTimestamp)
        }

        let eligibleAt = basisDate.addingTimeInterval(rule.lifetime.seconds)
        let grace = rule.gracePeriod?.seconds ?? settings.defaultGracePeriodSeconds
        let scheduledAt = eligibleAt.addingTimeInterval(grace)
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

    private static func isHiddenProtected(path: String, candidate: RuleCandidate, rule: LifetimeRule) -> Bool {
        if rule.matcher.explicitlyTargetsDotName { return false }
        let components: [Substring]
        switch rule.matchMode {
        case .scoped:
            guard let relative = rule.scope.relativePath(of: path) else { return false }
            components = relative.split(separator: "/")
        case .itemSpecific, .exactPath, .template:
            components = [Substring(candidate.name)]
        }
        return components.contains { $0.hasPrefix(".") }
    }
}
