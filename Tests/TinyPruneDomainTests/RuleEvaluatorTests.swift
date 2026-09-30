#if canImport(XCTest)
import XCTest
@testable import TinyPruneDomain

final class RuleEvaluatorTests: XCTestCase {
    func testPreviewRuleSchedulesAnExplainablePreviewWithoutActiveDisposition() throws {
        let rule = try makeRule(state: .preview, gracePeriod: try RuleDuration(seconds: 3_600))
        let modified = Date(timeIntervalSinceReferenceDate: 500_000)
        let candidate = makeCandidate(name: "node_modules", modified: modified)

        let result = RuleEvaluator.evaluate(candidate: candidate, against: rule)

        guard case .scheduled(let explanation) = result else {
            return XCTFail("Expected a scheduled preview candidate")
        }
        XCTAssertEqual(explanation.matchedRuleID, rule.id)
        XCTAssertEqual(explanation.matchedRuleName, "Old Node Modules")
        XCTAssertEqual(explanation.expiryBasis, .modified)
        XCTAssertEqual(explanation.basisDate, modified)
        XCTAssertEqual(explanation.eligibleAt, modified.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(explanation.scheduledAt, modified.addingTimeInterval(30 * 86_400 + 3_600))
        XCTAssertEqual(explanation.disposition, .preview)
    }

    func testPausedRuleNeverSchedulesCandidate() throws {
        let result = RuleEvaluator.evaluate(candidate: makeCandidate(name: "node_modules"), against: try makeRule(state: .paused))
        XCTAssertEqual(result, .suppressed(.pausedRule))
    }

    func testCandidateWithoutRequiredBasisIsSuppressed() throws {
        let candidate = RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([1]), pathHint: "/Developer/project/node_modules"),
            name: "node_modules",
            kind: .directory,
            timestamps: CandidateTimestamps()
        )
        XCTAssertEqual(RuleEvaluator.evaluate(candidate: candidate, against: try makeRule(state: .active)), .suppressed(.missingExpiryTimestamp))
    }

    func testMatcherRejectsWrongNameAndKind() throws {
        let rule = try makeRule(state: .active)
        XCTAssertEqual(RuleEvaluator.evaluate(candidate: makeCandidate(name: "dist"), against: rule), .suppressed(.itemDoesNotMatch))
        XCTAssertEqual(RuleEvaluator.evaluate(candidate: makeCandidate(name: "node_modules", kind: .file), against: rule), .suppressed(.itemDoesNotMatch))
    }

    func testInvalidRuleInputsAreRejected() throws {
        XCTAssertThrowsError(try RuleDuration(seconds: 0))
        XCTAssertThrowsError(try RuleScope(path: "  ", recursive: true))
        XCTAssertThrowsError(try ItemMatcher(itemKind: .directory, exactNames: [""]))
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
#endif
