import Testing
import Foundation
import TinyPruneDomain
@testable import TinyPruneIPC

@Suite struct ExplanationFormattingTests {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func identity(_ path: String) -> FilesystemIdentity {
        FilesystemIdentity(volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, resourceIdentifier: Data([1, 2, 3]), pathHint: path)
    }

    private func rule(state: RuleState = .active, lifetimeDays: Double = 7) throws -> LifetimeRule {
        try LifetimeRule(
            name: "Old downloads",
            scope: RuleScope(path: "/tmp/fixture", recursive: true),
            matcher: ItemMatcher(itemKind: .fileOrDirectory, exactNames: ["a.txt"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: lifetimeDays * 86_400),
            action: .trashItem,
            state: state
        )
    }

    private func explanation(
        path: String = "/tmp/fixture/a.txt",
        rules: [LifetimeRule],
        overrides: [ItemPolicyOverride] = [],
        modified: Date,
        paused: Bool = false
    ) -> AgentItemExplanation {
        let candidate = RuleCandidate(
            identity: identity(path), name: (path as NSString).lastPathComponent, kind: .file,
            timestamps: CandidateTimestamps(modified: modified)
        )
        let resolution = RuleResolver.resolve(candidate: candidate, rules: rules, overrides: overrides, globallyPaused: paused)
        return AgentItemExplanation(path: path, identity: candidate.identity, resolution: resolution, overrides: overrides, globallyPaused: paused)
    }

    @Test func scheduledActiveItemNamesRuleReasonAndTrashDate() throws {
        let item = explanation(rules: [try rule()], modified: now)
        guard case .scheduled(let scheduled) = item.resolution else { Issue.record("expected scheduled"); return }
        let text = ExplanationFormatter.summary(item, now: now, calendar: calendar(), locale: locale)
        #expect(text.hasPrefix("/tmp/fixture/a.txt\n"))
        #expect(text.contains("Scheduled: moves to the Trash on \(ExplanationFormatter.format(scheduled.scheduledAt, calendar: calendar(), locale: locale))."))
        #expect(text.contains("Rule: Old downloads"))
        #expect(text.contains("last modified"))
        // Never raw enum identifiers.
        #expect(!text.contains("modified since") && !text.contains("(active)"))
    }

    @Test func dueItemSaysDueNowRatherThanAPastSchedule() throws {
        let item = explanation(rules: [try rule(lifetimeDays: 1)], modified: now.addingTimeInterval(-10 * 86_400))
        let text = ExplanationFormatter.summary(item, now: now, calendar: calendar(), locale: locale)
        #expect(text.contains("Due now"))
    }

    @Test func previewRuleNeverClaimsItMovesAnything() throws {
        let item = explanation(rules: [try rule(state: .preview)], modified: now)
        let text = ExplanationFormatter.summary(item, now: now, calendar: calendar(), locale: locale)
        #expect(text.contains("Nothing is moved while the rule is in Preview"))
        #expect(!text.contains("moves to the Trash on"))
    }

    @Test func dateRespectsInjectedCalendarTimeZone() throws {
        let item = explanation(rules: [try rule()], modified: now)
        let utc = ExplanationFormatter.summary(item, now: now, calendar: calendar("UTC"), locale: locale)
        let tokyo = ExplanationFormatter.summary(item, now: now, calendar: calendar("Asia/Tokyo"), locale: locale)
        #expect(utc != tokyo)
        #expect(utc == ExplanationFormatter.summary(item, now: now, calendar: calendar("UTC"), locale: locale))
    }

    @Test func keepOnTheItemAndOnAnAncestorAreDistinguished() throws {
        let direct = ItemPolicyOverride(path: "/tmp/fixture/a.txt", policy: .keep(protectDescendants: false))
        let directText = ExplanationFormatter.summary(
            explanation(rules: [try rule()], overrides: [direct], modified: now), now: now, calendar: calendar(), locale: locale
        )
        #expect(directText.contains("Kept: TinyPrune will not touch this item."))

        let folder = ItemPolicyOverride(path: "/tmp/fixture", policy: .keep(protectDescendants: true))
        let inheritedText = ExplanationFormatter.summary(
            explanation(rules: [try rule()], overrides: [folder], modified: now), now: now, calendar: calendar(), locale: locale
        )
        #expect(inheritedText.contains("protected because /tmp/fixture is kept (including everything inside it)"))
    }

    @Test func suppressionAndNoRuleUsePlainLanguage() throws {
        let pausedExpiry = ItemPolicyOverride(path: "/tmp/fixture/a.txt", policy: .customExpiry(now.addingTimeInterval(3_600), state: .paused))
        let paused = ExplanationFormatter.summary(
            explanation(rules: [try rule()], overrides: [pausedExpiry], modified: now), now: now, calendar: calendar(), locale: locale
        )
        #expect(!paused.contains("pausedRule"))
        #expect(paused.contains("Not scheduled: the rule is paused"))

        let none = ExplanationFormatter.summary(explanation(rules: [], modified: now), now: now, calendar: calendar(), locale: locale)
        #expect(none.contains("No rule applies"))
    }

    @Test func globalPauseIsCalledOut() throws {
        let text = ExplanationFormatter.summary(
            explanation(rules: [try rule()], modified: now, paused: true), now: now, calendar: calendar(), locale: locale
        )
        #expect(text.contains("TinyPrune is paused"))
    }

    @Test func describeAddsOverridesWhileSummaryDoesNot() throws {
        let override = ItemPolicyOverride(path: "/tmp/fixture/a.txt", policy: .customExpiry(now.addingTimeInterval(3_600), state: .active))
        let item = explanation(rules: [try rule()], overrides: [override], modified: now)
        let summary = ExplanationFormatter.summary(item, now: now, calendar: calendar(), locale: locale)
        let described = ExplanationFormatter.describe(item, now: now, calendar: calendar(), locale: locale)
        #expect(!summary.contains("Overrides"))
        #expect(described.hasPrefix(summary))
        #expect(described.contains("Overrides:\n  /tmp/fixture/a.txt: expires"))

        let plain = ExplanationFormatter.describe(explanation(rules: [try rule()], modified: now), now: now, calendar: calendar(), locale: locale)
        #expect(plain.hasSuffix("Overrides: none"))
    }
}
