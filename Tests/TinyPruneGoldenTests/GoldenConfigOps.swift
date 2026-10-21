import Foundation
@testable import TinyPruneDomain

/// `config.parse` and `config.render` pin the restricted-YAML config-as-code format, including the exact
/// diagnostics shown to users. See `Fixtures/golden/README.md`.
extension GoldenOps {
    static func configParse(_ input: FixtureObject) throws -> FixtureObject {
        let document: ConfigDocument
        do {
            document = try ConfigDocument.parse(try string(input, "text"), homeDirectory: try string(input, "home"))
        } catch let error as ConfigError {
            return ["configError": ["line": error.line as Any? ?? NSNull(), "message": error.message]]
        }
        return [
            "version": document.version,
            "roots": document.roots.map { ["path": $0.path, "line": $0.line] as FixtureObject },
            "rules": document.rules.map { spec -> FixtureObject in
                var rule: FixtureObject = [
                    "name": spec.name,
                    "kind": spec.itemKind.rawValue,
                    "names": spec.exactNames,
                    "globs": spec.globPatterns,
                    "basis": spec.basis.rawValue,
                    "afterSeconds": spec.lifetime.seconds,
                    "line": spec.line,
                ]
                if let grace = spec.grace { rule["graceSeconds"] = grace.seconds }
                return rule
            },
            "exceptions": document.exceptions.map {
                ["path": $0.path, "protectDescendants": $0.protectDescendants, "line": $0.line] as FixtureObject
            },
            "ruleIds": document.roots.flatMap { root in
                document.rules.map { ["root": root.path, "rule": $0.name, "id": ConfigDocument.ruleID(name: $0.name, rootPath: root.path).uuidString] as FixtureObject }
            },
        ]
    }

    static func configRender(_ input: FixtureObject) throws -> FixtureObject {
        let rules = try (input["rules"] as? [FixtureObject] ?? []).map(rule)
        let roots = try (input["roots"] as? [String] ?? []).map { try ManagedRoot(displayName: "Root", path: $0, bookmarkData: Data([1])) }
        let overrides = try (input["overrides"] as? [FixtureObject] ?? []).map(override)
        return ["text": ConfigDocument.render(policy: rules, roots: roots, overrides: overrides)]
    }
}
