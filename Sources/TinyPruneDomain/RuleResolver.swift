import Foundation

public enum ItemOverridePolicy: Hashable, Codable, Sendable {
    case inherit
    case keep(protectDescendants: Bool)
    case customExpiry(Date, state: RuleState)
}

public struct ItemPolicyOverride: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let identity: FilesystemIdentity?
    public let path: String
    public let policy: ItemOverridePolicy

    public init(id: UUID = UUID(), identity: FilesystemIdentity? = nil, path: String, policy: ItemOverridePolicy) {
        self.id = id
        self.identity = identity
        self.path = RuleScope.normalized(path)
        self.policy = policy
    }

    func appliesExactly(to candidate: RuleCandidate) -> Bool {
        if let identity { return identity == candidate.identity }
        return path == RuleScope.normalized(candidate.identity.pathHint)
    }

    func protects(_ candidate: RuleCandidate) -> Bool {
        guard case .keep(let protectDescendants) = policy else { return false }
        let candidatePath = RuleScope.normalized(candidate.identity.pathHint)
        if appliesExactly(to: candidate) { return true }
        return protectDescendants && candidatePath.hasPrefix(path + "/")
    }
}

public struct CustomExpiryExplanation: Hashable, Codable, Sendable {
    public let candidateIdentity: FilesystemIdentity
    public let overrideID: UUID
    public let expiresAt: Date
    public let disposition: ScheduledDisposition
}

public struct ProtectionExplanation: Hashable, Codable, Sendable {
    public let candidateIdentity: FilesystemIdentity
    public let overrideID: UUID
    public let protectedPath: String
    public let protectsDescendants: Bool
}

public enum RuleResolution: Hashable, Codable, Sendable {
    case scheduled(CandidateExplanation)
    case customExpiry(CustomExpiryExplanation)
    case protected(ProtectionExplanation)
    case suppressed(EvaluationSuppression)
    case noRule
    case ambiguousRules([UUID])
    case ambiguousOverrides([UUID])
}

public enum RuleResolver {
    public static func resolve(
        candidate: RuleCandidate,
        rules: [LifetimeRule],
        overrides: [ItemPolicyOverride] = [],
        globallyPaused: Bool = false
    ) -> RuleResolution {
        var protection: ItemPolicyOverride?
        for override in overrides where override.protects(candidate) {
            guard let current = protection else {
                protection = override
                continue
            }
            if override.path.count > current.path.count ||
                (override.path.count == current.path.count && override.id.uuidString < current.id.uuidString) {
                protection = override
            }
        }
        if let protection {
            let protectDescendants: Bool
            if case .keep(let value) = protection.policy { protectDescendants = value } else { protectDescendants = false }
            return .protected(ProtectionExplanation(
                candidateIdentity: candidate.identity,
                overrideID: protection.id,
                protectedPath: protection.path,
                protectsDescendants: protectDescendants
            ))
        }

        let exactOverrides = overrides.filter { $0.appliesExactly(to: candidate) && !isInherit($0.policy) }
        if exactOverrides.count > 1 {
            return .ambiguousOverrides(exactOverrides.map(\.id).sorted { $0.uuidString < $1.uuidString })
        }
        if let override = exactOverrides.first {
            switch override.policy {
            case .inherit, .keep:
                break
            case .customExpiry(let expiresAt, let state):
                if state == .paused { return .suppressed(.pausedRule) }
                if globallyPaused { return .suppressed(.globalPause) }
                return .customExpiry(CustomExpiryExplanation(
                    candidateIdentity: candidate.identity,
                    overrideID: override.id,
                    expiresAt: expiresAt,
                    disposition: state == .preview ? .preview : .active
                ))
            }
        }
        if globallyPaused { return .suppressed(.globalPause) }

        let applicable = rules.compactMap { rule -> RuleRankedMatch? in
            guard rule.state != .paused else { return nil }
            switch rule.matchMode {
            case .itemSpecific:
                guard RuleScope.normalized(candidate.identity.pathHint) == rule.scope.path,
                      let specificity = rule.matcher.specificity(name: candidate.name, relativePath: candidate.name, kind: candidate.kind) else { return nil }
                return RuleRankedMatch(rule: rule, tier: 4, scopeDepth: rule.scope.path.count, matcherSpecificity: specificity)
            case .exactPath:
                guard RuleScope.normalized(candidate.identity.pathHint) == rule.scope.path,
                      let specificity = rule.matcher.specificity(name: candidate.name, relativePath: candidate.name, kind: candidate.kind) else { return nil }
                return RuleRankedMatch(rule: rule, tier: 3, scopeDepth: rule.scope.path.count, matcherSpecificity: specificity)
            case .scoped:
                guard let relativePath = rule.scope.relativePath(of: candidate.identity.pathHint),
                      let specificity = rule.matcher.specificity(name: candidate.name, relativePath: relativePath, kind: candidate.kind) else { return nil }
                return RuleRankedMatch(rule: rule, tier: 2, scopeDepth: rule.scope.path.count, matcherSpecificity: specificity)
            case .template:
                let relativePath = candidate.name
                guard let specificity = rule.matcher.specificity(name: candidate.name, relativePath: relativePath, kind: candidate.kind) else { return nil }
                return RuleRankedMatch(rule: rule, tier: 1, scopeDepth: 0, matcherSpecificity: specificity)
            }
        }
        guard let best = applicable.max(by: { $0 < $1 }) else { return .noRule }
        let tied = applicable.filter { $0.samePrecedence(as: best) }
        guard tied.count == 1, let selected = tied.first else {
            return .ambiguousRules(tied.map { $0.rule.id }.sorted { $0.uuidString < $1.uuidString })
        }

        switch RuleEvaluator.evaluate(candidate: candidate, against: selected.rule) {
        case .scheduled(let explanation): return .scheduled(explanation)
        case .suppressed(let reason): return .suppressed(reason)
        }
    }

    private static func isInherit(_ policy: ItemOverridePolicy) -> Bool {
        if case .inherit = policy { return true }
        return false
    }

}

private struct RuleRankedMatch: Comparable {
    let rule: LifetimeRule
    let tier: Int
    let scopeDepth: Int
    let matcherSpecificity: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.scopeDepth != rhs.scopeDepth { return lhs.scopeDepth < rhs.scopeDepth }
        return lhs.matcherSpecificity < rhs.matcherSpecificity
    }

    func samePrecedence(as other: Self) -> Bool {
        tier == other.tier && scopeDepth == other.scopeDepth && matcherSpecificity == other.matcherSpecificity
    }
}
