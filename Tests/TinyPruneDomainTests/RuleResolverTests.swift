import Testing
import Foundation
@testable import TinyPruneDomain

@Suite struct RuleResolverTests {
    @Test func testCloserScopeOverridesParentScope() throws {
        let parent = try makeRule(name: "Parent", scope: "/Developer", exactNames: ["node_modules"])
        let closer = try makeRule(name: "Team", scope: "/Developer/team", exactNames: ["node_modules"])

        let result = RuleResolver.resolve(candidate: candidate(path: "/Developer/team/project/node_modules"), rules: [parent, closer])

        #expect(scheduledName(result) == "Team")
    }

    @Test func testExactPathExceptionWinsOverScopedRules() throws {
        let scoped = try makeRule(name: "Scoped", scope: "/Developer", exactNames: ["node_modules"])
        let exception = try makeRule(name: "Exception", scope: "/Developer/project/node_modules", exactNames: ["node_modules"], matchMode: .exactPath)

        let result = RuleResolver.resolve(candidate: candidate(path: "/Developer/project/node_modules"), rules: [scoped, exception])

        #expect(scheduledName(result) == "Exception")
    }

    @Test func testRecursiveGlobMatchesAtScopeRootAndCannotCrossSingleStarSlash() throws {
        #expect(GlobPattern("**/node_modules").matches("node_modules"))
        #expect(GlobPattern("**/node_modules").matches("project/node_modules"))
        #expect(!(GlobPattern("*.zip").matches("archive/old.zip")))
        #expect(GlobPattern("*.zip").matches("new.zip"))
    }

    @Test func testClosestScopeWinsOverMoreSpecificPatternInParentScope() throws {
        let parentPattern = try makeRule(name: "Parent Pattern", scope: "/Developer", exactNames: [], globPatterns: ["**/node_modules"])
        let localName = try makeRule(name: "Local Name", scope: "/Developer/team", exactNames: ["node_modules"])

        let result = RuleResolver.resolve(candidate: candidate(path: "/Developer/team/project/node_modules"), rules: [parentPattern, localName])

        #expect(scheduledName(result) == "Local Name")
    }

    @Test func testEqualPrecedenceRulesAreReportedAsAmbiguous() throws {
        let first = try makeRule(name: "First", scope: "/Developer", exactNames: ["node_modules"])
        let second = try makeRule(name: "Second", scope: "/Developer", exactNames: ["node_modules"])

        let result = RuleResolver.resolve(candidate: candidate(path: "/Developer/project/node_modules"), rules: [first, second])

        guard case .ambiguousRules(let ids) = result else { Issue.record("Expected an ambiguity, got \(result)"); return }
        #expect(Set(ids) == Set([first.id, second.id]))
    }

    @Test func testKeepSubtreeSuppressesCandidateButFolderOnlyKeepAllowsDescendants() throws {
        let rule = try makeRule(name: "Developer cleanup", scope: "/Developer", exactNames: ["node_modules"])
        let subtreeKeep = ItemPolicyOverride(path: "/Developer/legacy", policy: .keep(protectDescendants: true))
        let folderOnlyKeep = ItemPolicyOverride(path: "/Developer/legacy", policy: .keep(protectDescendants: false))

        let child = candidate(path: "/Developer/legacy/node_modules")
        #expect(RuleResolver.resolve(candidate: child, rules: [rule], overrides: [subtreeKeep]) == .protected(ProtectionExplanation(candidateIdentity: child.identity, overrideID: subtreeKeep.id, protectedPath: "/Developer/legacy", protectsDescendants: true)))
        #expect(scheduledName(RuleResolver.resolve(candidate: child, rules: [rule], overrides: [folderOnlyKeep])) == "Developer cleanup")
    }

    @Test func testKeepAppliesToExactItemAndBeatsGlobalPause() throws {
        let candidate = candidate(path: "/Developer/project/node_modules")
        let keep = ItemPolicyOverride(identity: candidate.identity, path: candidate.identity.pathHint, policy: .keep(protectDescendants: false))

        guard case .protected = RuleResolver.resolve(candidate: candidate, rules: [], overrides: [keep], globallyPaused: true) else {
            Issue.record("Explicit Keep must remain the winning policy"); return
        }
    }
    @Test func testNestedKeepsRemainProtectedAndMostSpecificIsExplained() {
        let candidate = candidate(path: "/Developer/project/node_modules")
        let broad = ItemPolicyOverride(path: "/Developer", policy: .keep(protectDescendants: true))
        let local = ItemPolicyOverride(path: "/Developer/project", policy: .keep(protectDescendants: true))

        guard case .protected(let explanation) = RuleResolver.resolve(candidate: candidate, rules: [], overrides: [broad, local]) else {
            Issue.record("Overlapping Keeps must never become ambiguous or permit cleanup"); return
        }
        #expect(explanation.overrideID == local.id)
        #expect(explanation.protectedPath == local.path)
    }


    @Test func testIdentityMismatchDoesNotApplyStaleItemOverrideAtReusedPath() throws {
        let original = candidate(path: "/Developer/project/node_modules", resource: Data([1]))
        let replacement = candidate(path: original.identity.pathHint, resource: Data([2]))
        let keep = ItemPolicyOverride(identity: original.identity, path: original.identity.pathHint, policy: .keep(protectDescendants: false))
        let rule = try makeRule(name: "Developer cleanup", scope: "/Developer", exactNames: ["node_modules"])

        #expect(scheduledName(RuleResolver.resolve(candidate: replacement, rules: [rule], overrides: [keep])) == "Developer cleanup")
    }

    @Test func testCustomExpiryUsesExplicitDateAndGlobalPauseSuppressesIt() throws {
        let candidate = candidate(path: "/Developer/project/notes.tmp")
        let deadline = Date(timeIntervalSinceReferenceDate: 900_000)
        let custom = ItemPolicyOverride(path: candidate.identity.pathHint, policy: .customExpiry(deadline, state: .active))

        #expect(RuleResolver.resolve(candidate: candidate, rules: [], overrides: [custom]) == .customExpiry(CustomExpiryExplanation(candidateIdentity: candidate.identity, overrideID: custom.id, expiresAt: deadline, disposition: .active)))
        #expect(RuleResolver.resolve(candidate: candidate, rules: [], overrides: [custom], globallyPaused: true) == .suppressed(.globalPause))
    }

    @Test func testItemSpecificRuleWinsOverExactPathException() throws {
        let exception = try makeRule(name: "Path exception", scope: "/Developer/project/node_modules", exactNames: ["node_modules"], matchMode: .exactPath)
        let itemRule = try makeRule(name: "Item rule", scope: "/Developer/project/node_modules", exactNames: ["node_modules"], matchMode: .itemSpecific)

        #expect(scheduledName(RuleResolver.resolve(candidate: candidate(path: "/Developer/project/node_modules"), rules: [exception, itemRule])) == "Item rule")
    }

    @Test func testNonrecursiveScopeMatchesOnlyImmediateChildren() throws {
        let scope = try RuleScope(path: "/Downloads", recursive: false)
        #expect(scope.relativePath(of: "/Downloads/archive.zip") == "archive.zip")
        #expect(scope.relativePath(of: "/Downloads/old/archive.zip") == nil)
        #expect(scope.relativePath(of: "/DownloadsBackup/archive.zip") == nil)
    }

    @Test func testTemplateIsFallbackAfterScopedRules() throws {
        let template = try makeRule(name: "Template", scope: "/Templates", exactNames: ["node_modules"], matchMode: .template)
        let scoped = try makeRule(name: "Scoped", scope: "/Developer", exactNames: ["node_modules"])

        #expect(scheduledName(RuleResolver.resolve(candidate: candidate(path: "/Developer/project/node_modules"), rules: [template, scoped])) == "Scoped")
        #expect(scheduledName(RuleResolver.resolve(candidate: candidate(path: "/Projects/node_modules"), rules: [template])) == "Template")
    }
    @Test func testTemplateBasenameGlobMatchesAcrossUnrelatedFolders() throws {
        let template = try makeRule(name: "Zip archives", scope: "/Templates", exactNames: [], globPatterns: ["*.zip"], matchMode: .template)
        #expect(scheduledName(RuleResolver.resolve(candidate: candidate(path: "/Downloads/monthly/archive.zip"), rules: [template])) == "Zip archives")
    }

    @Test func testPathHintDoesNotChangeStableFilesystemIdentity() {
        let beforeRename = FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data([3, 4]), pathHint: "/Developer/old-name")
        let afterRename = FilesystemIdentity(volumeIdentifier: beforeRename.volumeIdentifier, resourceIdentifier: Data([3, 4]), pathHint: "/Developer/new-name")
        #expect(beforeRename == afterRename)
        #expect(Set([beforeRename, afterRename]).count == 1)
    }


    private func scheduledName(_ result: RuleResolution) -> String? {
        guard case .scheduled(let explanation) = result else { return nil }
        return explanation.matchedRuleName
    }

    private func makeRule(
        name: String,
        scope: String,
        exactNames: Set<String>,
        globPatterns: Set<String> = [],
        matchMode: RuleMatchMode = .scoped,
        state: RuleState = .active
    ) throws -> LifetimeRule {
        try LifetimeRule(
            name: name,
            scope: RuleScope(path: scope, recursive: true),
            matcher: ItemMatcher(itemKind: .directory, exactNames: exactNames, globPatterns: globPatterns),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 86_400),
            action: .trashItem,
            state: state,
            matchMode: matchMode
        )
    }

    private func candidate(path: String, resource: Data = Data([1, 2])) -> RuleCandidate {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return RuleCandidate(
            identity: FilesystemIdentity(volumeIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, resourceIdentifier: resource, pathHint: path),
            name: name,
            kind: .directory,
            timestamps: CandidateTimestamps(modified: Date(timeIntervalSinceReferenceDate: 500_000))
        )
    }
}
