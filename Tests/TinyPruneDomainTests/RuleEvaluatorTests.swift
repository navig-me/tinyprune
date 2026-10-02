import Testing
import Foundation
@testable import TinyPruneDomain

@Suite struct RuleEvaluatorTests {
    @Test func testPreviewRuleSchedulesAnExplainablePreviewWithoutActiveDisposition() throws {
        let rule = try makeRule(state: .preview, gracePeriod: try RuleDuration(seconds: 3_600))
        let modified = Date(timeIntervalSinceReferenceDate: 500_000)
        let candidate = makeCandidate(name: "node_modules", modified: modified)

        let result = RuleEvaluator.evaluate(candidate: candidate, against: rule)

        guard case .scheduled(let explanation) = result else {
            Issue.record("Expected a scheduled preview candidate"); return
        }
        #expect(explanation.matchedRuleID == rule.id)
        #expect(explanation.matchedRuleName == "Old Node Modules")
        #expect(explanation.expiryBasis == .modified)
        #expect(explanation.basisDate == modified)
        #expect(explanation.eligibleAt == modified.addingTimeInterval(30 * 86_400))
        #expect(explanation.scheduledAt == modified.addingTimeInterval(30 * 86_400 + 3_600))
        #expect(explanation.disposition == .preview)
    }

    @Test func testPausedRuleNeverSchedulesCandidate() throws {
        let result = RuleEvaluator.evaluate(candidate: makeCandidate(name: "node_modules"), against: try makeRule(state: .paused))
        #expect(result == .suppressed(.pausedRule))
    }

    @Test func testCandidateWithoutRequiredBasisIsSuppressed() throws {
        let candidate = RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([1]), pathHint: "/Developer/project/node_modules"),
            name: "node_modules",
            kind: .directory,
            timestamps: CandidateTimestamps()
        )
        #expect(RuleEvaluator.evaluate(candidate: candidate, against: try makeRule(state: .active)) == .suppressed(.missingExpiryTimestamp))
    }

    @Test func testMatcherRejectsWrongNameAndKind() throws {
        let rule = try makeRule(state: .active)
        #expect(RuleEvaluator.evaluate(candidate: makeCandidate(name: "dist"), against: rule) == .suppressed(.itemDoesNotMatch))
        #expect(RuleEvaluator.evaluate(candidate: makeCandidate(name: "node_modules", kind: .file), against: rule) == .suppressed(.itemDoesNotMatch))
    }

    @Test func testInvalidRuleInputsAreRejected() throws {
        #expect(throws: (any Error).self) { _ = try RuleDuration(seconds: 0) }
        #expect(throws: (any Error).self) { _ = try RuleScope(path: "  ", recursive: true) }
        #expect(throws: (any Error).self) { _ = try ItemMatcher(itemKind: .directory, exactNames: [""]) }
    }

    @Test func testDefaultGraceAppliesOnlyWhenRuleHasNoGraceOfItsOwn() throws {
        let modified = Date(timeIntervalSinceReferenceDate: 500_000)
        let settings = AgentSettings(defaultGracePeriodSeconds: 600)
        let candidate = makeCandidate(name: "node_modules", modified: modified)
        guard case .scheduled(let inherited) = RuleEvaluator.evaluate(candidate: candidate, against: try makeRule(state: .active), settings: settings),
              case .scheduled(let own) = RuleEvaluator.evaluate(candidate: candidate, against: try makeRule(state: .active, gracePeriod: try RuleDuration(seconds: 60)), settings: settings) else {
            Issue.record("Expected scheduled candidates"); return
        }
        #expect(inherited.scheduledAt == modified.addingTimeInterval(30 * 86_400 + 600))
        #expect(own.scheduledAt == modified.addingTimeInterval(30 * 86_400 + 60))
    }

    @Test func testHiddenProtectionSuppressesDotComponentsUnlessRuleTargetsDotNames() throws {
        let settings = AgentSettings(protectHiddenFiles: true)
        let hiddenParent = RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([4]), pathHint: "/Developer/.hidden/node_modules"),
            name: "node_modules",
            kind: .directory,
            timestamps: CandidateTimestamps(modified: Date(timeIntervalSinceReferenceDate: 500_000))
        )
        #expect(RuleEvaluator.evaluate(candidate: hiddenParent, against: try makeRule(state: .active), settings: settings) == .suppressed(.hiddenProtected))
        guard case .scheduled = RuleEvaluator.evaluate(candidate: hiddenParent, against: try makeRule(state: .active)) else {
            Issue.record("Hidden protection must be off by default"); return
        }
        let dotRule = try LifetimeRule(
            name: "Dot items",
            scope: try RuleScope(path: "/Developer", recursive: true),
            matcher: try ItemMatcher(itemKind: .file, exactNames: [".DS_Store"]),
            expiryBasis: .modified,
            lifetime: try RuleDuration(seconds: 60),
            action: .trashItem,
            state: .active
        )
        let dotItem = RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([5]), pathHint: "/Developer/project/.DS_Store"),
            name: ".DS_Store",
            kind: .file,
            timestamps: CandidateTimestamps(modified: Date(timeIntervalSinceReferenceDate: 500_000))
        )
        guard case .scheduled = RuleEvaluator.evaluate(candidate: dotItem, against: dotRule, settings: settings) else {
            Issue.record("Explicit dot-name rules are exempt from hidden protection"); return
        }
    }

    private func makeRule(state: RuleState, gracePeriod: RuleDuration? = nil) throws -> LifetimeRule {
        try LifetimeRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Old Node Modules",
            scope: try RuleScope(path: "/Developer", recursive: true),
            matcher: try ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
            expiryBasis: .modified,
            lifetime: try RuleDuration(seconds: 30 * 86_400),
            gracePeriod: gracePeriod,
            action: .trashItem,
            state: state
        )
    }

    private func makeCandidate(name: String, kind: ItemKind = .directory, modified: Date = Date(timeIntervalSinceReferenceDate: 500_000)) -> RuleCandidate {
        RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, resourceIdentifier: Data([1, 2]), pathHint: "/Developer/project/\(name)"),
            name: name,
            kind: kind,
            timestamps: CandidateTimestamps(modified: modified)
        )
    }
}
