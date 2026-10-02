import Foundation
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

/// The single evaluation path shared by the indexer (which persists deadlines) and the read-only rule preview.
/// It owns how persisted activity is overlaid on a filesystem candidate and how the rule set is resolved, so a
/// dry run and a real index pass cannot disagree about what a rule matches.
enum IndexedCandidateEvaluation {
    /// Read-only hydration; absent observation records are treated exactly like a first indexing pass.
    static func hydrate(
        _ candidate: RuleCandidate,
        rules: [LifetimeRule],
        store: SQLiteSafetyStore,
        now: Date,
        suppliedActivity: PersistedObservedActivity? = nil
    ) async throws -> RuleCandidate {
        var evaluated = candidate
        if usesObservedActivity(candidate, rules: rules) {
            let activity: PersistedObservedActivity
            if let suppliedActivity {
                activity = suppliedActivity
            } else if let existing = try await store.observedActivity(for: candidate.identity) {
                activity = PersistedObservedActivity(
                    identity: candidate.identity,
                    firstObservedAt: existing.firstObservedAt,
                    lastObservedAt: max(existing.lastObservedAt, candidate.timestamps.modified ?? existing.lastObservedAt)
                )
            } else {
                activity = PersistedObservedActivity(identity: candidate.identity, firstObservedAt: now, lastObservedAt: now)
            }
            evaluated = applying(observedActivity: activity, to: candidate)
        }
        if usesProjectActivity(candidate, rules: rules) {
            evaluated = applying(projectActivity: try await store.projectActivity(for: candidate.identity.pathHint), to: evaluated)
        }
        return evaluated
    }
    static func usesObservedActivity(_ candidate: RuleCandidate, rules: [LifetimeRule]) -> Bool {
        rules.contains { rule in
            (rule.expiryBasis == .firstObserved || rule.expiryBasis == .observedActivity) && ruleAppliesToCandidate(rule, candidate)
        }
    }

    static func usesProjectActivity(_ candidate: RuleCandidate, rules: [LifetimeRule]) -> Bool {
        rules.contains { rule in
            rule.expiryBasis == .projectActivity && ruleAppliesToCandidate(rule, candidate)
        }
    }

    static func applying(observedActivity activity: PersistedObservedActivity, to candidate: RuleCandidate) -> RuleCandidate {
        let timestamps = candidate.timestamps
        return RuleCandidate(
            identity: candidate.identity,
            name: candidate.name,
            kind: candidate.kind,
            timestamps: CandidateTimestamps(
                created: timestamps.created,
                modified: timestamps.modified,
                firstObserved: activity.firstObservedAt,
                observedActivity: activity.lastObservedAt,
                accessed: timestamps.accessed,
                projectActivity: timestamps.projectActivity,
                explicitDate: timestamps.explicitDate
            )
        )
    }

    static func applying(projectActivity: Date?, to candidate: RuleCandidate) -> RuleCandidate {
        let timestamps = candidate.timestamps
        return RuleCandidate(
            identity: candidate.identity,
            name: candidate.name,
            kind: candidate.kind,
            timestamps: CandidateTimestamps(
                created: timestamps.created,
                modified: timestamps.modified,
                firstObserved: timestamps.firstObserved,
                observedActivity: timestamps.observedActivity,
                accessed: timestamps.accessed,
                projectActivity: projectActivity,
                explicitDate: timestamps.explicitDate
            )
        )
    }

    /// Pause is enforced at execution time (scheduler idles, coordinator preflight suppresses). Deadlines are
    /// still indexed while paused so nothing seen during a pause needs a re-index when it lifts.
    static func resolve(_ candidate: RuleCandidate, rules: [LifetimeRule], snapshot: PolicySnapshot) -> RuleResolution {
        RuleResolver.resolve(
            candidate: candidate,
            rules: rules,
            overrides: snapshot.overrides,
            globallyPaused: false,
            settings: snapshot.settings
        )
    }

    private static func ruleAppliesToCandidate(_ rule: LifetimeRule, _ candidate: RuleCandidate) -> Bool {
        guard rule.state != .paused else { return false }
        let candidatePath = RuleScope.normalized(candidate.identity.pathHint)
        let relativePath: String
        switch rule.matchMode {
        case .scoped:
            guard let relative = rule.scope.relativePath(of: candidatePath) else { return false }
            relativePath = relative
        case .exactPath, .itemSpecific:
            guard candidatePath == rule.scope.path else { return false }
            relativePath = candidate.name
        case .template:
            relativePath = candidate.name
        }
        return rule.matcher.matches(name: candidate.name, relativePath: relativePath, kind: candidate.kind)
    }
}
