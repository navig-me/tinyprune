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

// Templates must produce ordinary valid rules that resolve without ambiguity.
for template in RuleTemplate.allCases {
    let produced = try template.rules(in: "/Users/example/Work", state: .preview)
    guard !produced.isEmpty, produced.allSatisfy({ $0.state == .preview && !$0.naturalDescription().isEmpty }) else {
        throw SmokeFailure.incorrectResolution
    }
}
let downloadsRules = try RuleTemplate.downloads.rules(in: "/Users/example/Downloads", state: .active)
func downloadsCandidate(_ name: String) -> RuleCandidate {
    RuleCandidate(
        identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data(name.utf8), pathHint: "/Users/example/Downloads/\(name)"),
        name: name,
        kind: .file,
        timestamps: CandidateTimestamps(firstObserved: Date(timeIntervalSince1970: 0))
    )
}
for (name, days) in [("a.dmg", 7.0), ("b.zip", 14.0), ("c.pdf", 30.0)] {
    guard case .scheduled(let item) = RuleResolver.resolve(candidate: downloadsCandidate(name), rules: downloadsRules),
          item.scheduledAt == Date(timeIntervalSince1970: days * 86_400) else {
        throw SmokeFailure.incorrectResolution
    }
}
guard try makeRule(state: .preview).naturalDescription(homeDirectory: "/Users/example").contains("node_modules") else {
    throw SmokeFailure.incorrectResolution
}

// MARK: Config as code (spec §41)
let configHome = "/Users/example"
let specConfig = """
version: 1

roots:
  - ~/Developer   # trailing comment

rules:
  - name: Node dependencies
    match:
      directories:
        - node_modules
    expiry:
      after: 30d
      since: project_activity
    action: trash

  - name: Python environments
    match:
      directories: [.venv, venv]
      globs:
        - "**/.cache dir"
    expiry:
      after: 45d
      since: project_activity
      grace: 2d
    action: trash

exceptions:
  - path: ~/Developer/legacy-production
    protect: descendants
  - path: /Users/example/Developer/pinned
    protect: item
"""
let configDocument = try ConfigDocument.parse(specConfig, homeDirectory: configHome)
guard configDocument.roots.map(\.path) == ["/Users/example/Developer"],
      configDocument.rules.count == 2,
      configDocument.rules[1].exactNames == [".venv", "venv"],
      configDocument.rules[1].globPatterns == ["**/.cache dir"],
      configDocument.rules[1].grace?.seconds == 2 * 86_400,
      configDocument.rules[0].basis == .projectActivity,
      configDocument.rules[0].itemKind == .directory else { throw SmokeFailure.incorrectResolution }
let configRules = try configDocument.rules(state: .preview)
guard configRules.count == 2, configRules.allSatisfy({ $0.state == .preview && $0.scope.recursive && $0.action == .trashItem && ConfigDocument.isConfigRule($0) }),
      configRules.map(\.id) == (try configDocument.rules(state: .active)).map(\.id),
      configRules[0].id != configRules[1].id else { throw SmokeFailure.incorrectResolution }
guard configDocument.overrides().map(\.policy) == [.keep(protectDescendants: true), .keep(protectDescendants: false)],
      configDocument.overrides()[0].path == "/Users/example/Developer/legacy-production" else { throw SmokeFailure.incorrectResolution }

// Two roots multiply rules, with distinct deterministic IDs.
let twoRoots = try ConfigDocument.parse("""
version: 1
roots: [~/A, "/Users/example/B"]
rules:
  - name: Tmp
    match:
      names: [tmp]
    expiry:
      after: 1d
      since: modified
""", homeDirectory: configHome)
guard try twoRoots.rules(state: .preview).count == 2,
      Set(try twoRoots.rules(state: .preview).map(\.id)).count == 2 else { throw SmokeFailure.incorrectResolution }

// Round trip through the exporter.
let exportRoot = try ManagedRoot(displayName: "Developer", path: "/Users/example/Developer", bookmarkData: Data([1]))
let exported = ConfigDocument.render(policy: configRules, roots: [exportRoot], overrides: configDocument.overrides())
let reparsed = try ConfigDocument.parse(exported, homeDirectory: configHome)
guard reparsed.roots.map(\.path) == configDocument.roots.map(\.path),
      try reparsed.rules(state: .preview) == configRules,
      reparsed.overrides().map(\.path) == configDocument.overrides().map(\.path),
      reparsed.overrides().map(\.policy) == configDocument.overrides().map(\.policy) else { throw SmokeFailure.incorrectResolution }

// ConfigPlan: add / unchanged / change / remove / unmanaged root / exceptions.
let planRoot = try ManagedRoot(displayName: "Developer", path: "/Users/example/Developer", bookmarkData: Data([1]))
let freshPlan = try ConfigPlan.make(document: configDocument, currentRules: [], currentRoots: [planRoot], currentOverrides: [], activate: false)
guard freshPlan.added.count == 2, freshPlan.added.allSatisfy({ $0.state == .preview }), freshPlan.changed.isEmpty,
      freshPlan.removed.isEmpty, freshPlan.unchanged == 0, freshPlan.unmanagedRoots.isEmpty, freshPlan.isApplicable,
      freshPlan.merged == freshPlan.added, freshPlan.hasRuleChanges, freshPlan.addsPreviewRules,
      freshPlan.exceptions.count == 2, freshPlan.exceptions.allSatisfy(\.isNew),
      freshPlan.summaryLines.first == "Roots:", freshPlan.summaryLines.contains("Rules to add (2):"),
      freshPlan.summaryLines.contains("  /Users/example/Developer  managed") else { throw SmokeFailure.incorrectResolution }

let activePlan = try ConfigPlan.make(document: configDocument, currentRules: [], currentRoots: [planRoot], currentOverrides: [], activate: true)
guard activePlan.added.allSatisfy({ $0.state == .active }), !activePlan.addsPreviewRules else { throw SmokeFailure.incorrectResolution }

// Re-planning against the applied result is a no-op and keeps IDs; existing exceptions are not new.
let appliedOverrides = configDocument.overrides()
let settledPlan = try ConfigPlan.make(document: configDocument, currentRules: freshPlan.merged, currentRoots: [planRoot], currentOverrides: appliedOverrides, activate: false)
guard !settledPlan.hasRuleChanges, settledPlan.unchanged == 2, settledPlan.merged == freshPlan.merged,
      settledPlan.exceptions.allSatisfy({ !$0.isNew }), settledPlan.newExceptions.isEmpty,
      settledPlan.summaryLines.contains("Rules: no changes (2 already up to date).") else { throw SmokeFailure.incorrectResolution }

// Activation changes only state; an app-made rule on the same root is never touched, and a stale config rule is removed.
let appRule = try LifetimeRule(
    name: "Mine", scope: RuleScope(path: "/Users/example/Developer", recursive: true),
    matcher: ItemMatcher(itemKind: .file, exactNames: ["x"]), expiryBasis: .modified,
    lifetime: RuleDuration(seconds: 3_600), action: .trashItem, state: .active
)
let staleRule = try LifetimeRule(
    id: ConfigDocument.ruleID(name: "Gone", rootPath: "/Users/example/Developer"),
    name: "Gone", scope: RuleScope(path: "/Users/example/Developer", recursive: true),
    matcher: ItemMatcher(itemKind: .file, exactNames: ["y"]), expiryBasis: .modified,
    lifetime: RuleDuration(seconds: 3_600), action: .trashItem, state: .active
)
let mixedPlan = try ConfigPlan.make(
    document: configDocument, currentRules: [appRule, staleRule] + freshPlan.merged, currentRoots: [planRoot],
    currentOverrides: [], activate: true
)
guard mixedPlan.added.isEmpty, mixedPlan.changed.count == 2, mixedPlan.changed.allSatisfy({ $0.fields == ["state"] }),
      mixedPlan.removed.map(\.name) == ["Gone"],
      mixedPlan.merged.first == appRule, mixedPlan.merged.count == 3,
      mixedPlan.merged.dropFirst().allSatisfy({ $0.state == .active }),
      mixedPlan.summaryLines.contains("Rules to remove (1):") else { throw SmokeFailure.incorrectResolution }

// A changed definition is reported with the changed field names and keeps its current state.
let altered = try ConfigDocument.parse("""
version: 1
roots: [/Users/example/Developer]
rules:
  - name: \(configDocument.rules[0].name)
    match:
      names: [different]
    expiry:
      after: 1d
      since: modified
""", homeDirectory: configHome)
let alteredPlan = try ConfigPlan.make(document: altered, currentRules: freshPlan.merged, currentRoots: [planRoot], currentOverrides: [], activate: false)
guard alteredPlan.changed.count == 1, alteredPlan.changed[0].fields.contains("match"),
      alteredPlan.changed[0].after.state == .preview else { throw SmokeFailure.incorrectResolution }

// Roots outside every managed root block apply; sibling prefixes do not count as inside.
let strayPlan = try ConfigPlan.make(document: twoRoots, currentRules: [], currentRoots: [planRoot], currentOverrides: [], activate: false)
guard strayPlan.unmanagedRoots == ["/Users/example/A", "/Users/example/B"],
      !strayPlan.isApplicable else { throw SmokeFailure.incorrectResolution }
let siblingRoot = try ManagedRoot(displayName: "Dev", path: "/Users/example/Dev", bookmarkData: Data([1]))
let siblingPlan = try ConfigPlan.make(document: configDocument, currentRules: [], currentRoots: [siblingRoot], currentOverrides: [], activate: false)
guard siblingPlan.unmanagedRoots == ["/Users/example/Developer"],
      siblingPlan.summaryLines.contains(where: { $0.contains("NOT MANAGED") }),
      siblingPlan.summaryLines.last == "Apply is blocked until every root is managed." else { throw SmokeFailure.incorrectResolution }

// Rules the format cannot express are reported, not silently dropped.
let explicitRule = try LifetimeRule(
    name: "One shot", scope: RuleScope(path: "/Users/example/Developer", recursive: true),
    matcher: ItemMatcher(itemKind: .file, exactNames: ["a"]), expiryBasis: .explicitDate,
    lifetime: RuleDuration(seconds: 60), action: .trashItem, state: .preview
)
guard ConfigDocument.render(policy: [explicitRule], roots: [exportRoot], overrides: []).contains("# - rule 'One shot'") else {
    throw SmokeFailure.incorrectResolution
}

// Rejections carry the offending line number.
func expectConfigError(_ text: String, line: Int, contains fragment: String) throws {
    do {
        _ = try ConfigDocument.parse(text, homeDirectory: configHome)
    } catch let error as ConfigError {
        guard error.line == line, error.message.contains(fragment) else {
            print("config error mismatch: \(error) (wanted line \(line), '\(fragment)')")
            throw SmokeFailure.incorrectResolution
        }
        return
    }
    print("config parsed but should fail: \(fragment)")
    throw SmokeFailure.incorrectResolution
}
let ruleHead = "version: 1\nroots:\n  - ~/Developer\nrules:\n  - name: R\n    match:\n      directories: [x]\n    expiry:\n"
try expectConfigError("version: 2\nroots:\n  - ~/a\n", line: 1, contains: "Unsupported version")
try expectConfigError("version: 1\nroots:\n  - Developer\n", line: 3, contains: "relative path")
try expectConfigError("version: 1\nroots:\n  - ~/a\nbogus: 1\n", line: 4, contains: "Unknown key 'bogus'")
try expectConfigError(ruleHead + "      after: soon\n      since: modified\n", line: 9, contains: "duration")
try expectConfigError(ruleHead + "      after: 0d\n      since: modified\n", line: 9, contains: "duration")
try expectConfigError(ruleHead + "      after: 3d\n      since: whenever\n", line: 10, contains: "since must be")
try expectConfigError(ruleHead + "      after: 3d\n      since: modified\n      extra: 1\n", line: 11, contains: "Unknown key 'extra'")
try expectConfigError(ruleHead + "      after: 3d\n      since: modified\n    action: delete\n", line: 11, contains: "action must be 'trash'")
try expectConfigError("version: 1\nroots:\n  - ~/a\nexceptions:\n  - path: ~/b/c\n    protect: item\n", line: 5, contains: "not inside any listed root")
try expectConfigError("version: 1\nroots:\n  - ~/a\nexceptions:\n  - path: ~/a/c\n    protect: all\n", line: 6, contains: "protect must be")
try expectConfigError("version: 1\nroots:\n\t- ~/a\n", line: 3, contains: "Tabs")
try expectConfigError("version: 1\nroots:\n  - ~/a\n  - ~/a/b\n", line: 4, contains: "overlaps")
try expectConfigError("version: 1\nroots:\n  - ~/a\nrules:\n  - name: R\n    match:\n      globs:\n        - *.dmg\n    expiry:\n      after: 1d\n      since: created\n", line: 8, contains: "wrap the value in quotes")
try expectConfigError("version: 1\nroots:\n  - ~/a\nrules:\n  - name: R\n    match: {names: [a]}\n", line: 6, contains: "Inline mappings")

print("TinyPrune domain smoke passed")
