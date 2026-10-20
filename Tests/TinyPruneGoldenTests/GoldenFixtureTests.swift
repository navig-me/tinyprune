import Testing
import Foundation
@testable import TinyPruneDomain

/// Verifies `Fixtures/golden/*.jsonl` against the Swift domain implementation.
///
/// The fixtures are the language-neutral behavior contract that any other implementation (the planned Rust
/// core) must reproduce byte-for-byte; see `Fixtures/golden/README.md` for the schema. Each line is one case:
/// `{"name", "op", "input", "expected"}`. Inputs are hand-authored. After an intentional behavior change, run
/// `TINYPRUNE_UPDATE_GOLDEN=1 swift test --filter GoldenFixtureTests` to rewrite `expected`, then review the diff.
@Suite struct GoldenFixtureTests {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    static var fixtureFiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    @Test func fixtureFilesExist() {
        #expect(!Self.fixtureFiles.isEmpty)
    }

    @Test(arguments: GoldenFixtureTests.fixtureFiles)
    func fixtureMatchesImplementation(file: String) async throws {
        let url = Self.fixtureDirectory.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        let update = ProcessInfo.processInfo.environment["TINYPRUNE_UPDATE_GOLDEN"] == "1"
        var rewritten: [String] = []
        var seenNames = Set<String>()
        var unprocessable = false

        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let label = "\(file):\(offset + 1)"
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = object["name"] as? String,
                  let op = object["op"] as? String,
                  let input = object["input"] as? [String: Any] else {
                Issue.record("\(label): malformed case (need name, op, input)")
                unprocessable = true
                continue
            }
            guard seenNames.insert(name).inserted else {
                Issue.record("\(label): duplicate case name \(name)")
                unprocessable = true
                continue
            }

            let actual: [String: Any]
            do {
                actual = try await GoldenOps.run(op: op, input: input)
            } catch let error as RuleValidationError {
                actual = ["error": String(describing: error)]
            } catch {
                Issue.record("\(label) \(name): \(error)")
                unprocessable = true
                continue
            }

            if update {
                rewritten.append(Self.render(name: name, note: object["note"] as? String, op: op, input: input, expected: actual))
            } else if let expected = object["expected"] as? [String: Any] {
                let lhs = try Self.canonical(expected), rhs = try Self.canonical(actual)
                #expect(lhs == rhs, "\(label) \(name)\n  expected \(lhs)\n  actual   \(rhs)")
            } else {
                Issue.record("\(label) \(name): missing expected; run with TINYPRUNE_UPDATE_GOLDEN=1")
            }
        }

        if update {
            // Never rewrite a file that lost a case: the update would silently delete it.
            if unprocessable { Issue.record("\(file): not rewritten because some cases could not be processed") }
            else { try (rewritten.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// Canonical form: round-tripped (so `87400` and `87400.0` agree) with sorted keys.
    static func canonical(_ value: Any) throws -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        let reparsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return String(decoding: try JSONSerialization.data(withJSONObject: reparsed, options: options), as: UTF8.self)
    }

    static func render(name: String, note: String?, op: String, input: [String: Any], expected: [String: Any]) -> String {
        var parts = ["\"name\":" + ((try? canonical(name)) ?? "\"\"")]
        if let note { parts.append("\"note\":" + ((try? canonical(note)) ?? "\"\"")) }
        parts.append("\"op\":" + ((try? canonical(op)) ?? "\"\""))
        parts.append("\"input\":" + ((try? canonical(input)) ?? "{}"))
        parts.append("\"expected\":" + ((try? canonical(expected)) ?? "{}"))
        return "{" + parts.joined(separator: ",") + "}"
    }
}

struct FixtureFormatError: Error, CustomStringConvertible {
    let description: String
}

typealias FixtureObject = [String: Any]

/// Decodes fixture JSON into domain values and encodes results back. Deliberately uses only public
/// initializers (plus `@testable` specificity) so the schema stays a statement of the contract, not of internals.
enum GoldenOps {
    static let defaultVolume = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!

    static func run(op: String, input: FixtureObject) async throws -> FixtureObject {
        switch op {
        case "glob":
            let relative = try string(input, "relativePath")
            let name = (input["name"] as? String) ?? lastComponent(relative)
            return ["matches": GlobPattern(try string(input, "pattern")).matches(name: name, relativePath: relative)]
        case "path.normalize":
            return ["path": RuleScope.normalized(try string(input, "path"))]
        case "scope.relative":
            let scope = try scope(try object(input, "scope"))
            return ["relative": scope.relativePath(of: try string(input, "path")) as Any? ?? NSNull()]
        case "matcher.match":
            let matcher = try matcher(try object(input, "matcher"))
            let relative = try string(input, "relativePath")
            let name = (input["name"] as? String) ?? lastComponent(relative)
            let kind = try itemKind(input["kind"] as? String ?? "file")
            let specificity = matcher.specificity(name: name, relativePath: relative, kind: kind)
            return ["matches": specificity != nil, "specificity": specificity as Any? ?? NSNull()]
        case "rule.validate":
            _ = try rule(try object(input, "rule"))
            return ["valid": true]
        case "identity.equals":
            return ["equal": try identity(try object(input, "a")) == identity(try object(input, "b"))]
        case "evaluate":
            let evaluation = RuleEvaluator.evaluate(
                candidate: try candidate(try object(input, "candidate")),
                against: try rule(try object(input, "rule")),
                settings: try settings(input["settings"] as? FixtureObject)
            )
            switch evaluation {
            case .scheduled(let explanation): return encode(explanation)
            case .suppressed(let reason): return ["result": "suppressed", "reason": reason.rawValue]
            }
        case "resolve":
            let resolution = RuleResolver.resolve(
                candidate: try candidate(try object(input, "candidate")),
                rules: try (input["rules"] as? [FixtureObject] ?? []).map(rule),
                overrides: try (input["overrides"] as? [FixtureObject] ?? []).map(override),
                globallyPaused: input["globallyPaused"] as? Bool ?? false,
                settings: try settings(input["settings"] as? FixtureObject)
            )
            return encode(resolution)
        case "keep.covers":
            let covers = RuleResolver.keepCovers(
                candidateIdentity: try (input["identity"] as? FixtureObject).map(identity),
                candidatePath: try string(input, "path"),
                override: try override(try object(input, "override")),
                keptItemCurrentPath: input["keptItemCurrentPath"] as? String
            )
            return ["covers": covers]
        case "keep.protectsDescendant":
            let protects = RuleResolver.keepProtectsDescendant(
                of: try string(input, "ancestor"),
                override: try override(try object(input, "override")),
                childIdentity: try (input["childIdentity"] as? FixtureObject).map(identity),
                childPath: try string(input, "childPath"),
                keptItemCurrentPath: input["keptItemCurrentPath"] as? String
            )
            return ["protects": protects]
        case "schedule.scan":
            return try await scheduleScan(input)
        case "trash.execute":
            return try await trashExecute(input)
        case "config.parse":
            return try configParse(input)
        case "config.render":
            return try configRender(input)
        case "template.rules", "broadness", "root.validate", "config.plan":
            return try domainOperation(op, input)
        default:
            throw FixtureFormatError(description: "unknown op \(op)")
        }
    }

    // MARK: Decoding

    static func string(_ object: FixtureObject, _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw FixtureFormatError(description: "missing string \(key)") }
        return value
    }

    static func object(_ object: FixtureObject, _ key: String) throws -> FixtureObject {
        guard let value = object[key] as? FixtureObject else { throw FixtureFormatError(description: "missing object \(key)") }
        return value
    }

    static func date(_ value: Any?) -> Date? {
        (value as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func uuid(_ object: FixtureObject, _ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(object, key)) else { throw FixtureFormatError(description: "bad uuid \(key)") }
        return value
    }

    static func hexData(_ hex: String) throws -> Data {
        guard hex.count % 2 == 0 else { throw FixtureFormatError(description: "odd hex \(hex)") }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw FixtureFormatError(description: "bad hex \(hex)") }
            data.append(byte)
            index = next
        }
        return data
    }

    static func itemKind(_ raw: String) throws -> ItemKind {
        guard let kind = ItemKind(rawValue: raw) else { throw FixtureFormatError(description: "bad kind \(raw)") }
        return kind
    }

    static func identity(_ object: FixtureObject) throws -> FilesystemIdentity {
        FilesystemIdentity(
            volumeIdentifier: try (object["volume"] as? String).map { _ in try uuid(object, "volume") } ?? defaultVolume,
            resourceIdentifier: try hexData(object["resource"] as? String ?? "01"),
            pathHint: try string(object, "path"),
            creationTime: date(object["created"]),
            generation: (object["generation"] as? Int).map { UInt32($0) },
            isPersistent: object["persistent"] as? Bool ?? true
        )
    }

    static func candidate(_ object: FixtureObject) throws -> RuleCandidate {
        let identity = try identity(object)
        let stamps = object["timestamps"] as? FixtureObject ?? [:]
        return RuleCandidate(
            identity: identity,
            name: object["name"] as? String ?? lastComponent(identity.pathHint),
            kind: try itemKind(object["kind"] as? String ?? "directory"),
            timestamps: CandidateTimestamps(
                created: date(stamps["created"]),
                modified: date(stamps["modified"]),
                firstObserved: date(stamps["firstObserved"]),
                observedActivity: date(stamps["observedActivity"]),
                accessed: date(stamps["accessed"]),
                projectActivity: date(stamps["projectActivity"]),
                explicitDate: date(stamps["explicitDate"])
            )
        )
    }

    static func scope(_ object: FixtureObject) throws -> RuleScope {
        try RuleScope(path: try string(object, "path"), recursive: object["recursive"] as? Bool ?? true)
    }

    static func matcher(_ object: FixtureObject) throws -> ItemMatcher {
        try ItemMatcher(
            itemKind: try itemKind(object["kind"] as? String ?? "fileOrDirectory"),
            exactNames: Set(object["names"] as? [String] ?? []),
            globPatterns: Set(object["globs"] as? [String] ?? [])
        )
    }

    static func rule(_ object: FixtureObject) throws -> LifetimeRule {
        func raw<T: RawRepresentable>(_ key: String, _ fallback: T) throws -> T where T.RawValue == String {
            guard let text = object[key] as? String else { return fallback }
            guard let value = T(rawValue: text) else { throw FixtureFormatError(description: "bad \(key) \(text)") }
            return value
        }
        return try LifetimeRule(
            id: try uuid(object, "id"),
            name: object["name"] as? String ?? "Rule",
            scope: try scope(try self.object(object, "scope")),
            matcher: try matcher(object["matcher"] as? FixtureObject ?? [:]),
            expiryBasis: try raw("basis", ExpiryBasis.modified),
            lifetime: try RuleDuration(seconds: object["lifetime"] as? Double ?? 86_400),
            gracePeriod: try (object["grace"] as? Double).map { try RuleDuration(seconds: $0) },
            action: try raw("action", FolderAction.trashItem),
            state: try raw("state", RuleState.active),
            matchMode: try raw("mode", RuleMatchMode.scoped)
        )
    }

    static func override(_ object: FixtureObject) throws -> ItemPolicyOverride {
        let policyObject = try self.object(object, "policy")
        let policy: ItemOverridePolicy
        switch try string(policyObject, "type") {
        case "inherit": policy = .inherit
        case "keep": policy = .keep(protectDescendants: policyObject["protectDescendants"] as? Bool ?? false)
        case "customExpiry":
            guard let expires = date(policyObject["expiresAt"]) else { throw FixtureFormatError(description: "missing expiresAt") }
            policy = .customExpiry(expires, state: RuleState(rawValue: policyObject["state"] as? String ?? "active") ?? .active)
        default: throw FixtureFormatError(description: "bad policy type")
        }
        return ItemPolicyOverride(
            id: try uuid(object, "id"),
            identity: try (object["identity"] as? FixtureObject).map(identity),
            path: try string(object, "path"),
            policy: policy
        )
    }

    static func settings(_ object: FixtureObject?) throws -> AgentSettings {
        AgentSettings(
            defaultGracePeriodSeconds: object?["defaultGraceSeconds"] as? Double ?? 0,
            protectHiddenFiles: object?["protectHiddenFiles"] as? Bool ?? false
        )
    }

    // MARK: Encoding

    static func encode(_ explanation: CandidateExplanation) -> FixtureObject {
        var result: FixtureObject = [
            "result": "scheduled",
            "ruleId": explanation.matchedRuleID.uuidString,
            "ruleName": explanation.matchedRuleName,
            "basis": explanation.expiryBasis.rawValue,
            "basisDate": explanation.basisDate.timeIntervalSince1970,
            "eligibleAt": explanation.eligibleAt.timeIntervalSince1970,
            "scheduledAt": explanation.scheduledAt.timeIntervalSince1970,
            "disposition": explanation.disposition.rawValue,
        ]
        if let id = explanation.customOverrideID { result["customOverrideId"] = id.uuidString }
        return result
    }

    static func encode(_ resolution: RuleResolution) -> FixtureObject {
        switch resolution {
        case .scheduled(let explanation):
            return encode(explanation)
        case .customExpiry(let custom):
            return [
                "result": "customExpiry",
                "overrideId": custom.overrideID.uuidString,
                "expiresAt": custom.expiresAt.timeIntervalSince1970,
                "disposition": custom.disposition.rawValue,
            ]
        case .protected(let protection):
            return [
                "result": "protected",
                "overrideId": protection.overrideID.uuidString,
                "protectedPath": protection.protectedPath,
                "protectsDescendants": protection.protectsDescendants,
            ]
        case .suppressed(let reason):
            return ["result": "suppressed", "reason": reason.rawValue]
        case .noRule:
            return ["result": "noRule"]
        case .ambiguousRules(let ids):
            return ["result": "ambiguousRules", "ids": ids.map(\.uuidString)]
        case .ambiguousOverrides(let ids):
            return ["result": "ambiguousOverrides", "ids": ids.map(\.uuidString)]
        }
    }
}
