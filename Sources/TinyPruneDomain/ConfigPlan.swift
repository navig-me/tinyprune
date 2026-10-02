import Foundation

/// Declarative diff between a ``ConfigDocument`` and the current policy. Pure and deterministic: the CLI and
/// the app both build their preview/apply from this one implementation. Config-created rules are recognized
/// by their deterministic ID, so rules made in the app are never changed or removed.
public struct ConfigPlan: Equatable, Sendable {
    public struct RuleChange: Equatable, Sendable {
        public let before: LifetimeRule
        public let after: LifetimeRule
        /// Names of the changed fields, e.g. `match`, `since`, `after`, `state`.
        public let fields: [String]
    }

    public struct ExceptionChange: Equatable, Sendable {
        public let override: ItemPolicyOverride
        /// False when an identical override is already present.
        public let isNew: Bool
    }

    /// Root paths from the document, in document order.
    public let roots: [String]
    /// Document roots that are not inside any managed root.
    public let unmanagedRoots: [String]
    public let added: [LifetimeRule]
    public let changed: [RuleChange]
    public let removed: [LifetimeRule]
    public let unchanged: Int
    /// Current rules after removals, replacements, and additions, in that order.
    public let merged: [LifetimeRule]
    public let exceptions: [ExceptionChange]

    public var hasRuleChanges: Bool { !added.isEmpty || !changed.isEmpty || !removed.isEmpty }
    /// Exceptions that still need to be set.
    public var newExceptions: [ItemPolicyOverride] { exceptions.filter(\.isNew).map(\.override) }
    /// Apply is allowed only when every root is managed.
    public var isApplicable: Bool { unmanagedRoots.isEmpty }
    /// True when applying would add new rules that start in Preview.
    public var addsPreviewRules: Bool { added.contains { $0.state == .preview } }

    /// - Parameter activate: New and existing config rules become active; otherwise new rules start in Preview and
    ///   existing rules keep their state.
    public static func make(
        document: ConfigDocument,
        currentRules: [LifetimeRule],
        currentRoots: [ManagedRoot],
        currentOverrides: [ItemPolicyOverride],
        activate: Bool
    ) throws -> ConfigPlan {
        let desired = try document.rules(state: .preview)
        let desiredIDs = Set(desired.map(\.id))
        let existing = Dictionary(currentRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var replacements: [UUID: LifetimeRule] = [:]
        var added: [LifetimeRule] = []
        var changed: [RuleChange] = []
        var unchanged = 0

        for rule in desired {
            let state: RuleState = activate ? .active : existing[rule.id]?.state ?? .preview
            let target = try rule.withState(state)
            guard let current = existing[rule.id] else {
                added.append(target)
                continue
            }
            let fields = differences(current, target)
            if fields.isEmpty {
                unchanged += 1
            } else {
                changed.append(RuleChange(before: current, after: target, fields: fields))
                replacements[rule.id] = target
            }
        }

        let rootPaths = document.roots.map(\.path)
        let rootSet = Set(rootPaths)
        let removed = currentRules.filter {
            ConfigDocument.isConfigRule($0) && rootSet.contains($0.scope.path) && !desiredIDs.contains($0.id)
        }
        let removedIDs = Set(removed.map(\.id))
        let merged = currentRules.filter { !removedIDs.contains($0.id) }.map { replacements[$0.id] ?? $0 } + added

        let unmanaged = rootPaths.filter { root in
            !currentRoots.contains { root == $0.path || root.hasPrefix($0.path + "/") }
        }
        let exceptions = document.overrides().map { wanted in
            let present = currentOverrides.contains { $0.path == wanted.path && $0.policy == wanted.policy }
            return ExceptionChange(override: wanted, isNew: !present)
        }
        return ConfigPlan(
            roots: rootPaths, unmanagedRoots: unmanaged, added: added, changed: changed, removed: removed,
            unchanged: unchanged, merged: merged, exceptions: exceptions
        )
    }

    /// Human-readable preview lines (roots, rule diff, exceptions, blocking note). Contains no document header.
    public var summaryLines: [String] {
        var lines = ["Roots:"]
        for root in roots {
            lines.append("  \(root)  \(unmanagedRoots.contains(root) ? "NOT MANAGED - add this folder in TinyPrune.app before applying" : "managed")")
        }
        if !added.isEmpty {
            lines.append("Rules to add (\(added.count)):")
            lines += added.map { "  + \(Self.describe($0))" }
        }
        if !changed.isEmpty {
            lines.append("Rules to change (\(changed.count)):")
            lines += changed.map { "  ~ \(Self.describe($0.after))  [\($0.fields.joined(separator: ", "))]" }
        }
        if !removed.isEmpty {
            lines.append("Rules to remove (\(removed.count)):")
            lines += removed.map { "  - \(Self.describe($0))" }
        }
        if !hasRuleChanges { lines.append("Rules: no changes (\(unchanged) already up to date).") }
        for exception in exceptions {
            let kind: String
            if case .keep(let descendants) = exception.override.policy {
                kind = descendants ? "keep with descendants" : "keep item"
            } else {
                kind = "override"
            }
            lines.append("  \(exception.isNew ? "+" : "=") exception \(exception.override.path)  \(kind)")
        }
        if !unmanagedRoots.isEmpty { lines.append("Apply is blocked until every root is managed.") }
        return lines
    }

    /// One-line rule description shared by CLI and app.
    public static func describe(_ rule: LifetimeRule) -> String {
        "\(rule.name)  \(rule.scope.path)  \(rule.state.rawValue)  \(matcherDescription(rule))  \(rule.expiryBasis.rawValue) for \(durationDescription(rule.lifetime.seconds))"
    }

    public static func matcherDescription(_ rule: LifetimeRule) -> String {
        let values = rule.matcher.exactNames.sorted() + rule.matcher.globPatterns.sorted()
        let kind = rule.matcher.itemKind.rawValue
        return "\(kind) \(values.isEmpty ? "items" : values.joined(separator: ", "))"
    }

    public static func durationDescription(_ seconds: TimeInterval) -> String {
        let day: TimeInterval = 86_400
        if seconds.truncatingRemainder(dividingBy: day) == 0 { return "\(Int(seconds / day))d" }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds))s"
    }

    private static func differences(_ old: LifetimeRule, _ new: LifetimeRule) -> [String] {
        var fields: [String] = []
        if old.matcher != new.matcher { fields.append("match") }
        if old.expiryBasis != new.expiryBasis { fields.append("since") }
        if old.lifetime != new.lifetime { fields.append("after") }
        if old.gracePeriod != new.gracePeriod { fields.append("grace") }
        if old.action != new.action { fields.append("action") }
        if old.scope != new.scope { fields.append("scope") }
        if old.matchMode != new.matchMode { fields.append("matchMode") }
        if old.state != new.state { fields.append("state") }
        return fields
    }
}

private extension LifetimeRule {
    func withState(_ state: RuleState) throws -> LifetimeRule {
        try LifetimeRule(
            id: id, name: name, scope: scope, matcher: matcher, expiryBasis: expiryBasis, lifetime: lifetime,
            gracePeriod: gracePeriod, action: action, state: state, matchMode: matchMode
        )
    }
}
