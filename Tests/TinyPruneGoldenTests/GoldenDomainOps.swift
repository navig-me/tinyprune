import Foundation
@testable import TinyPruneDomain

extension GoldenOps {
    static func encodeRule(_ rule: LifetimeRule) -> FixtureObject {
        ["id": rule.id.uuidString, "name": rule.name, "scope": ["path": rule.scope.path, "recursive": rule.scope.recursive],
         "matcher": ["kind": rule.matcher.itemKind.rawValue, "names": rule.matcher.exactNames.sorted(), "globs": rule.matcher.globPatterns.sorted()],
         "basis": rule.expiryBasis.rawValue, "lifetime": rule.lifetime.seconds, "grace": rule.gracePeriod?.seconds as Any? ?? NSNull(),
         "action": rule.action.rawValue, "state": rule.state.rawValue, "mode": rule.matchMode.rawValue]
    }

    static func domainOperation(_ op: String, _ input: FixtureObject) throws -> FixtureObject {
        switch op {
        case "template.rules":
            guard let template = RuleTemplate(rawValue: try string(input, "template")),
                  let state = RuleState(rawValue: input["state"] as? String ?? "active") else {
                throw FixtureFormatError(description: "invalid template or state")
            }
            let rules = try template.rules(in: string(input, "path"), state: state, temporaryLifetime: input["temporaryLifetime"] as? Double ?? 259200)
            return ["title": template.title, "summary": template.summary, "suggestedFolder": template.suggestedFolder as Any? ?? NSNull(), "isBroad": template.isBroad,
                    "rules": rules.map { rule -> FixtureObject in var value = encodeRule(rule); value.removeValue(forKey: "id"); return value }]
        case "broadness":
            if let value = input["rule"] as? FixtureObject {
                let rule = try rule(value)
                return ["isVeryBroad": rule.isVeryBroad, "isBroad": rule.isBroad]
            }
            let lexical = RuleScope.isVeryBroad(path: try string(input, "path"))
            let resolved = (input["resolvedPath"] as? String).map { RuleScope.isVeryBroad(path: $0) } ?? false
            return ["isVeryBroad": lexical || resolved]
        case "root.validate":
            do {
                let root = try ManagedRoot(displayName: input["name"] as? String ?? "Root", path: string(input, "path"), bookmarkData: Data(repeating: 1, count: input["bookmarkBytes"] as? Int ?? 1))
                // Feed a scripted resolver result through the same public validation boundary.
                // Actual realpath traversal belongs to platform adapter tests, not portable fixtures.
                if let resolved = input["resolvedPath"] as? String {
                    _ = try ManagedRoot(displayName: root.displayName, path: resolved, bookmarkData: root.bookmarkData)
                }
                return ["valid": true, "path": root.path, "isVeryBroad": root.isVeryBroad || (input["resolvedPath"] as? String).map { RuleScope.isVeryBroad(path: $0) } == true]
            } catch let error as ManagedRootValidationError { return ["error": String(describing: error)] }
        case "config.plan":
            let document = try ConfigDocument.parse(string(input, "text"), homeDirectory: input["home"] as? String ?? "/Users/fixture")
            var current = try (input["currentRules"] as? [FixtureObject] ?? []).map(rule)
            if let previous = input["previousText"] as? String {
                let old = try ConfigDocument.parse(previous, homeDirectory: "/Users/fixture")
                current += try old.rules(state: RuleState(rawValue: input["previousState"] as? String ?? "preview")!)
            }
            let roots = try (input["managedRoots"] as? [String] ?? []).map { try ManagedRoot(displayName: "Root", path: $0, bookmarkData: Data([1])) }
            let plan = try ConfigPlan.make(document: document, currentRules: current, currentRoots: roots,
                                           currentOverrides: (input["overrides"] as? [FixtureObject] ?? []).map(override), activate: input["activate"] as? Bool ?? false)
            return ["roots": plan.roots, "unmanagedRoots": plan.unmanagedRoots, "added": plan.added.map(encodeRule),
                    "changed": plan.changed.map { ["before": encodeRule($0.before), "after": encodeRule($0.after), "fields": $0.fields] as FixtureObject },
                    "removed": plan.removed.map(encodeRule), "unchanged": plan.unchanged, "merged": plan.merged.map(encodeRule),
                    "exceptions": plan.exceptions.map { change -> FixtureObject in
                        guard case .keep(let descendants) = change.override.policy else { preconditionFailure() }
                        return ["path": change.override.path, "protectDescendants": descendants, "isNew": change.isNew]
                    }, "hasRuleChanges": plan.hasRuleChanges, "isApplicable": plan.isApplicable, "addsPreviewRules": plan.addsPreviewRules,
                    "newExceptions": plan.newExceptions.map(\.path), "summaryLines": plan.summaryLines]
        default: throw FixtureFormatError(description: "unknown domain op")
        }
    }
}
