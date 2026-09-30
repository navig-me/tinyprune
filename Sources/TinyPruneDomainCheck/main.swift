import Foundation
import TinyPruneDomain

enum SmokeFailure: Error {
    case expectedScheduledPreview
    case incorrectPreviewExplanation
    case expectedPausedSuppression
    case incorrectResolution
}

func makeRule(state: RuleState) throws -> LifetimeRule {
    try LifetimeRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Old Node Modules",
        scope: try RuleScope(path: "/Developer", recursive: true),
        matcher: try ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
        expiryBasis: .modified,
        lifetime: try RuleDuration(seconds: 30 * 86_400),
        action: .trashItem,
        state: state
    )
}

let modified = Date(timeIntervalSinceReferenceDate: 500_000)
let candidate = RuleCandidate(
    identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([1]), pathHint: "/Developer/project/node_modules"),
    name: "node_modules",
    kind: .directory,
    timestamps: CandidateTimestamps(modified: modified)
)

let preview = try makeRule(state: .preview)
guard case .scheduled(let explanation) = RuleEvaluator.evaluate(candidate: candidate, against: preview) else {
    throw SmokeFailure.expectedScheduledPreview
}
guard explanation.disposition == .preview,
      explanation.eligibleAt == modified.addingTimeInterval(30 * 86_400),
      explanation.matchedRuleID == preview.id else {
    throw SmokeFailure.incorrectPreviewExplanation
}

guard RuleEvaluator.evaluate(candidate: candidate, against: try makeRule(state: .paused)) == .suppressed(.pausedRule) else {
    throw SmokeFailure.expectedPausedSuppression
}

let scopeRule = try makeRule(state: .active)
let exactRule = try LifetimeRule(
    name: "Exact item rule",
    scope: try RuleScope(path: candidate.identity.pathHint, recursive: true),
    matcher: try ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
    expiryBasis: .modified,
    lifetime: try RuleDuration(seconds: 3_600),
    action: .trashItem,
    state: .active,
    matchMode: .itemSpecific
)
guard case .scheduled(let resolved) = RuleResolver.resolve(candidate: candidate, rules: [scopeRule, exactRule]),
      resolved.matchedRuleName == "Exact item rule" else {
    throw SmokeFailure.incorrectResolution
}

let keep = ItemPolicyOverride(path: "/Developer/project", policy: .keep(protectDescendants: true))
guard case .protected = RuleResolver.resolve(candidate: candidate, rules: [scopeRule], overrides: [keep]) else {
    throw SmokeFailure.incorrectResolution
}

guard GlobPattern("**/node_modules").matches("node_modules"),
      GlobPattern("*.zip").matches("archive.zip"),
      !GlobPattern("*.zip").matches("old/archive.zip") else {
    throw SmokeFailure.incorrectResolution
}

print("TinyPrune domain smoke passed")
