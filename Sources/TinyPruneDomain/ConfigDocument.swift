import CryptoKit
import Foundation

/// A located configuration problem. `line` is 1-based and nil only for whole-document problems.
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int?
    public let message: String

    public init(line: Int?, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String {
        guard let line else { return message }
        return "line \(line): \(message)"
    }
}

/// Spec §41 config-as-code: a deliberately restricted YAML subset. Every file this parser
/// accepts is also valid YAML; anything outside the subset is rejected with a line number.
public struct ConfigDocument: Equatable, Sendable {
    public struct Root: Equatable, Sendable {
        public let path: String
        public let line: Int
    }

    public struct RuleSpec: Equatable, Sendable {
        public let name: String
        public let itemKind: ItemKind
        public let exactNames: [String]
        public let globPatterns: [String]
        public let basis: ExpiryBasis
        public let lifetime: RuleDuration
        public let grace: RuleDuration?
        public let line: Int
    }

    public struct Exception: Equatable, Sendable {
        public let path: String
        public let protectDescendants: Bool
        public let line: Int
    }

    public let version: Int
    public let roots: [Root]
    public let rules: [RuleSpec]
    public let exceptions: [Exception]

    // MARK: Derived policy

    /// Deterministic UUID (version-5 layout over SHA-256) so re-applying a config is idempotent.
    public static func ruleID(name: String, rootPath: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data("tinyprune.config\u{0}\(name)\u{0}\(rootPath)".utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// True when the rule's identity is exactly what a config would have generated for it.
    public static func isConfigRule(_ rule: LifetimeRule) -> Bool {
        rule.id == ruleID(name: rule.name, rootPath: rule.scope.path)
    }

    /// One recursive rule per root × spec rule.
    public func rules(state: RuleState = .preview) throws -> [LifetimeRule] {
        try roots.flatMap { root in
            try rules.map { spec in
                try LifetimeRule(
                    id: Self.ruleID(name: spec.name, rootPath: root.path),
                    name: spec.name,
                    scope: RuleScope(path: root.path, recursive: true),
                    matcher: ItemMatcher(itemKind: spec.itemKind, exactNames: Set(spec.exactNames), globPatterns: Set(spec.globPatterns)),
                    expiryBasis: spec.basis,
                    lifetime: spec.lifetime,
                    gracePeriod: spec.grace,
                    action: .trashItem,
                    state: state
                )
            }
        }
    }

    /// Exceptions as Keep overrides. They must be applied through the agent, which verifies the path is managed.
    public func overrides() -> [ItemPolicyOverride] {
        exceptions.map {
            ItemPolicyOverride(path: $0.path, policy: .keep(protectDescendants: $0.protectDescendants))
        }
    }

    // MARK: Validation

    public func validate() throws {
        guard version == 1 else { throw ConfigError(line: 1, message: "Unsupported version \(version); only version 1 is supported.") }
        guard !roots.isEmpty else { throw ConfigError(line: nil, message: "At least one root is required.") }
        for (index, root) in roots.enumerated() {
            for other in roots[..<index] {
                if other.path == root.path {
                    throw ConfigError(line: root.line, message: "Duplicate root \(root.path).")
                }
                if root.path.hasPrefix(other.path + "/") || other.path.hasPrefix(root.path + "/") {
                    throw ConfigError(line: root.line, message: "Root \(root.path) overlaps root \(other.path); list only the outer folder.")
                }
            }
        }
        var names = Set<String>()
        for rule in rules {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError(line: rule.line, message: "Rule name must not be empty.")
            }
            guard names.insert(rule.name).inserted else {
                throw ConfigError(line: rule.line, message: "Duplicate rule name '\(rule.name)'.")
            }
            guard !rule.exactNames.isEmpty || !rule.globPatterns.isEmpty else {
                throw ConfigError(line: rule.line, message: "Rule '\(rule.name)' must match something.")
            }
        }
        var exceptionPaths = Set<String>()
        for exception in exceptions {
            guard exceptionPaths.insert(exception.path).inserted else {
                throw ConfigError(line: exception.line, message: "Duplicate exception for \(exception.path).")
            }
            guard roots.contains(where: { exception.path.hasPrefix($0.path + "/") }) else {
                throw ConfigError(line: exception.line, message: "Exception \(exception.path) is not inside any listed root.")
            }
        }
    }

    // MARK: Parsing

    public static func parse(_ text: String, homeDirectory: String) throws -> ConfigDocument {
        guard homeDirectory.hasPrefix("/") else { throw ConfigError(line: nil, message: "Home directory must be absolute.") }
        let root = try ConfigSyntax.parse(text)
        guard case .map(let entries, _) = root else {
            throw ConfigError(line: root.line, message: "Top level must be a mapping.")
        }
        let top = try fields(entries, allowed: ["version", "roots", "rules", "exceptions"], required: ["version", "roots"], context: "top level")

        let versionNode = top["version"]!
        guard case .scalar(let versionText, _) = versionNode.value else {
            throw ConfigError(line: versionNode.value.line, message: "version must be a number.")
        }
        guard versionText == "1" else {
            throw ConfigError(line: versionNode.value.line, message: "Unsupported version '\(versionText)'; only version 1 is supported.")
        }

        let roots = try strings(top["roots"]!.value, what: "roots").map { raw, line -> Root in
            Root(path: try expand(raw, home: homeDirectory, line: line), line: line)
        }
        guard !roots.isEmpty else { throw ConfigError(line: top["roots"]!.value.line, message: "roots must not be empty.") }

        var rules: [RuleSpec] = []
        if let node = top["rules"] {
            for item in try list(node.value, what: "rules") { rules.append(try parseRule(item)) }
        }
        var exceptions: [Exception] = []
        if let node = top["exceptions"] {
            for item in try list(node.value, what: "exceptions") {
                exceptions.append(try parseException(item, home: homeDirectory))
            }
        }

        let document = ConfigDocument(version: 1, roots: roots, rules: rules, exceptions: exceptions)
        try document.validate()
        return document
    }

    private static func parseRule(_ node: ConfigSyntax.Node) throws -> RuleSpec {
        guard case .map(let entries, _) = node else { throw ConfigError(line: node.line, message: "Each rule must be a mapping.") }
        let rule = try fields(entries, allowed: ["name", "match", "expiry", "action"], required: ["name", "match", "expiry"], context: "rule", line: node.line)

        guard case .scalar(let name, let nameLine) = rule["name"]!.value, !name.isEmpty else {
            throw ConfigError(line: rule["name"]!.value.line, message: "Rule name must be a non-empty string.")
        }
        if let action = rule["action"] {
            guard case .scalar("trash", _) = action.value else {
                throw ConfigError(line: action.value.line, message: "action must be 'trash'.")
            }
        }

        guard case .map(let matchEntries, let matchLine) = rule["match"]!.value else {
            throw ConfigError(line: rule["match"]!.value.line, message: "match must be a mapping.")
        }
        let match = try fields(matchEntries, allowed: ["directories", "files", "names", "globs"], required: [], context: "match", line: matchLine)
        if match["directories"] != nil, match["files"] != nil {
            throw ConfigError(line: match["files"]!.keyLine, message: "match cannot list both directories and files; use names for either.")
        }
        var names: [String] = []
        for key in ["directories", "files", "names"] {
            guard let entry = match[key] else { continue }
            for (value, line) in try strings(entry.value, what: key) {
                guard !value.contains("/") else { throw ConfigError(line: line, message: "\(key) entries are bare names and cannot contain '/'; use globs for paths.") }
                names.append(value)
            }
        }
        var globs: [String] = []
        if let entry = match["globs"] {
            for (value, line) in try strings(entry.value, what: "globs") {
                guard !value.hasPrefix("/") else { throw ConfigError(line: line, message: "globs are relative to the root and cannot start with '/'.") }
                globs.append(value)
            }
        }
        guard !names.isEmpty || !globs.isEmpty else {
            throw ConfigError(line: matchLine, message: "match needs at least one of directories, files, names, or globs.")
        }
        let kind: ItemKind = match["directories"] != nil ? .directory : match["files"] != nil ? .file : .fileOrDirectory

        guard case .map(let expiryEntries, let expiryLine) = rule["expiry"]!.value else {
            throw ConfigError(line: rule["expiry"]!.value.line, message: "expiry must be a mapping.")
        }
        let expiry = try fields(expiryEntries, allowed: ["after", "since", "grace"], required: ["after", "since"], context: "expiry", line: expiryLine)
        let lifetime = try duration(expiry["after"]!.value, what: "after")
        let grace = try expiry["grace"].map { try duration($0.value, what: "grace") }
        guard case .scalar(let sinceText, _) = expiry["since"]!.value, let basis = basis(named: sinceText) else {
            throw ConfigError(line: expiry["since"]!.value.line, message: "since must be one of \(basisNames.map(\.0).joined(separator: ", ")).")
        }

        return RuleSpec(
            name: name,
            itemKind: kind,
            exactNames: Array(Set(names)).sorted(),
            globPatterns: Array(Set(globs)).sorted(),
            basis: basis,
            lifetime: lifetime,
            grace: grace,
            line: nameLine
        )
    }

    private static func parseException(_ node: ConfigSyntax.Node, home: String) throws -> Exception {
        guard case .map(let entries, _) = node else { throw ConfigError(line: node.line, message: "Each exception must be a mapping.") }
        let item = try fields(entries, allowed: ["path", "protect"], required: ["path", "protect"], context: "exception", line: node.line)
        guard case .scalar(let raw, let line) = item["path"]!.value else {
            throw ConfigError(line: item["path"]!.value.line, message: "path must be a string.")
        }
        guard case .scalar(let protect, _) = item["protect"]!.value, protect == "descendants" || protect == "item" else {
            throw ConfigError(line: item["protect"]!.value.line, message: "protect must be 'descendants' or 'item'.")
        }
        return Exception(path: try expand(raw, home: home, line: line), protectDescendants: protect == "descendants", line: line)
    }

    // MARK: Parsing helpers

    private struct Field { let keyLine: Int; let value: ConfigSyntax.Node }

    private static func fields(
        _ entries: [ConfigSyntax.Entry], allowed: Set<String>, required: Set<String>, context: String, line: Int? = nil
    ) throws -> [String: Field] {
        var result: [String: Field] = [:]
        for entry in entries {
            guard allowed.contains(entry.key) else {
                throw ConfigError(line: entry.line, message: "Unknown key '\(entry.key)' in \(context); allowed: \(allowed.sorted().joined(separator: ", ")).")
            }
            result[entry.key] = Field(keyLine: entry.line, value: entry.value)
        }
        for key in required.sorted() where result[key] == nil {
            throw ConfigError(line: line ?? entries.first?.line ?? 1, message: "Missing required key '\(key)' in \(context).")
        }
        return result
    }

    private static func list(_ node: ConfigSyntax.Node, what: String) throws -> [ConfigSyntax.Node] {
        guard case .list(let items, _) = node else { throw ConfigError(line: node.line, message: "\(what) must be a list.") }
        return items
    }

    private static func strings(_ node: ConfigSyntax.Node, what: String) throws -> [(String, Int)] {
        try list(node, what: what).map { item in
            guard case .scalar(let value, let line) = item, !value.isEmpty else {
                throw ConfigError(line: item.line, message: "\(what) entries must be non-empty strings.")
            }
            return (value, line)
        }
    }

    private static func expand(_ raw: String, home: String, line: Int) throws -> String {
        let absolute: String
        if raw == "~" {
            absolute = home
        } else if raw.hasPrefix("~/") {
            absolute = home + "/" + raw.dropFirst(2)
        } else if raw.hasPrefix("~") {
            throw ConfigError(line: line, message: "'\(raw)': only ~ and ~/ are supported.")
        } else if raw.hasPrefix("/") {
            absolute = raw
        } else {
            throw ConfigError(line: line, message: "'\(raw)' is a relative path; use an absolute path or one starting with ~/.")
        }
        let normalized = RuleScope.normalized(absolute)
        guard normalized != "/" else { throw ConfigError(line: line, message: "The filesystem root cannot be used.") }
        return normalized
    }

    private static func duration(_ node: ConfigSyntax.Node, what: String) throws -> RuleDuration {
        guard case .scalar(let text, _) = node,
              let unit = text.last,
              let multiplier: TimeInterval = ["m": 60, "h": 3_600, "d": 86_400, "w": 604_800][unit],
              let amount = Int(text.dropLast()), amount > 0,
              let value = try? RuleDuration(seconds: TimeInterval(amount) * multiplier) else {
            throw ConfigError(line: node.line, message: "\(what) must be a positive duration such as 12h, 30d, or 2w.")
        }
        return value
    }

    private static let basisNames: [(String, ExpiryBasis)] = [
        ("project_activity", .projectActivity), ("modified", .modified), ("created", .created),
        ("first_observed", .firstObserved), ("observed_activity", .observedActivity), ("accessed", .accessed),
    ]

    private static func basis(named name: String) -> ExpiryBasis? { basisNames.first { $0.0 == name }?.1 }
    private static func name(of basis: ExpiryBasis) -> String? { basisNames.first { $0.1 == basis }?.0 }

    // MARK: Rendering

    /// Exports the policy in config format. Rules the format cannot express are listed in trailing comments.
    public static func render(policy rules: [LifetimeRule], roots: [ManagedRoot], overrides: [ItemPolicyOverride]) -> String {
        let rootPaths = roots.map(\.path).sorted()
        var skipped: [String] = []

        struct Definition: Hashable {
            let name: String, kind: ItemKind, names: [String], globs: [String]
            let basis: ExpiryBasis, lifetime: RuleDuration, grace: RuleDuration?
        }
        var order: [Definition] = []
        var scopes: [Definition: Set<String>] = [:]
        for rule in rules {
            if let reason = unexpressible(rule) {
                skipped.append("rule '\(rule.name)' (\(rule.scope.path)): \(reason)")
                continue
            }
            let definition = Definition(
                name: rule.name, kind: rule.matcher.itemKind, names: rule.matcher.exactNames.sorted(),
                globs: rule.matcher.globPatterns.sorted(), basis: rule.expiryBasis, lifetime: rule.lifetime, grace: rule.gracePeriod
            )
            if scopes[definition] == nil { order.append(definition) }
            scopes[definition, default: []].insert(rule.scope.path)
        }

        var lines = ["version: 1", "", "roots:"]
        lines += rootPaths.map { "  - \(scalar($0))" }
        var rendered = Set<String>()
        var ruleLines: [String] = []
        for definition in order {
            guard scopes[definition] == Set(rootPaths) else {
                skipped.append("rule '\(definition.name)': applies to \(scopes[definition]!.sorted().joined(separator: ", ")), not to every root")
                continue
            }
            guard rendered.insert(definition.name).inserted else {
                skipped.append("rule '\(definition.name)': another rule already uses this name")
                continue
            }
            ruleLines.append("  - name: \(scalar(definition.name))")
            ruleLines.append("    match:")
            let kindKey = definition.kind == .directory ? "directories" : definition.kind == .file ? "files" : "names"
            if !definition.names.isEmpty {
                ruleLines.append("      \(kindKey):")
                ruleLines += definition.names.map { "        - \(scalar($0))" }
            }
            if !definition.globs.isEmpty {
                ruleLines.append("      globs:")
                ruleLines += definition.globs.map { "        - \(scalar($0))" }
            }
            ruleLines.append("    expiry:")
            ruleLines.append("      after: \(durationText(definition.lifetime)!)")
            ruleLines.append("      since: \(name(of: definition.basis)!)")
            if let grace = definition.grace { ruleLines.append("      grace: \(durationText(grace)!)") }
            ruleLines.append("    action: trash")
            ruleLines.append("")
        }
        if !ruleLines.isEmpty {
            lines += ["", "rules:"] + ruleLines.dropLast()
        }

        var exceptionLines: [String] = []
        for override in overrides.sorted(by: { $0.path < $1.path }) {
            guard case .keep(let descendants) = override.policy else {
                skipped.append("override \(override.path): only Keep overrides can be expressed")
                continue
            }
            guard rootPaths.contains(where: { override.path.hasPrefix($0 + "/") }) else {
                skipped.append("override \(override.path): not inside a managed root")
                continue
            }
            exceptionLines.append("  - path: \(scalar(override.path))")
            exceptionLines.append("    protect: \(descendants ? "descendants" : "item")")
        }
        if !exceptionLines.isEmpty { lines += ["", "exceptions:"] + exceptionLines }

        if !skipped.isEmpty {
            lines += ["", "# Not exported (cannot be expressed in this format):"]
            lines += skipped.map { "# - " + $0.replacingOccurrences(of: "\n", with: " ") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func unexpressible(_ rule: LifetimeRule) -> String? {
        if rule.matchMode != .scoped { return "not a scoped rule" }
        if !rule.scope.recursive { return "not recursive" }
        if rule.action != .trashItem { return "action is not trash" }
        if name(of: rule.expiryBasis) == nil { return "expiry basis \(rule.expiryBasis.rawValue)" }
        if durationText(rule.lifetime) == nil || rule.gracePeriod.map({ durationText($0) == nil }) == true { return "duration is not a whole number of minutes" }
        let matcher = rule.matcher
        if matcher.exactNames.isEmpty && matcher.globPatterns.isEmpty { return "matches every item" }
        if matcher.exactNames.contains(where: { $0.contains("/") }) { return "name contains '/'" }
        if matcher.globPatterns.contains(where: { $0.hasPrefix("/") }) { return "absolute glob" }
        if matcher.itemKind != .fileOrDirectory, matcher.exactNames.isEmpty { return "\(matcher.itemKind.rawValue)-only glob rule" }
        return nil
    }

    private static func durationText(_ duration: RuleDuration) -> String? {
        let seconds = duration.seconds
        guard seconds == seconds.rounded() else { return nil }
        for (suffix, unit) in [("w", 604_800.0), ("d", 86_400.0), ("h", 3_600.0), ("m", 60.0)] where seconds.truncatingRemainder(dividingBy: unit) == 0 {
            return "\(Int(seconds / unit))\(suffix)"
        }
        return nil
    }

    private static func scalar(_ value: String) -> String {
        let plain = value.range(of: #"^[A-Za-z0-9_./][A-Za-z0-9 _./+@()-]*$"#, options: .regularExpression) != nil
            && !value.hasSuffix(" ") && value != "~" && !value.hasPrefix("~")
        if plain { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Restricted YAML syntax

enum ConfigSyntax {
    struct Entry { let key: String; let value: Node; let line: Int }

    indirect enum Node {
        case scalar(String, Int)
        case list([Node], Int)
        case map([Entry], Int)

        var line: Int {
            switch self {
            case .scalar(_, let line), .list(_, let line), .map(_, let line): line
            }
        }
    }

    private struct Line { let number: Int; let indent: Int; let text: String }

    static func parse(_ text: String) throws -> Node {
        var parser = Parser(lines: try tokenize(text))
        guard !parser.lines.isEmpty else { throw ConfigError(line: nil, message: "The file is empty.") }
        let node = try parser.block(indent: parser.lines[0].indent)
        if parser.position < parser.lines.count {
            throw ConfigError(line: parser.lines[parser.position].number, message: "Unexpected indentation.")
        }
        return node
    }

    private static func tokenize(_ text: String) throws -> [Line] {
        var result: [Line] = []
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, raw) in rawLines.enumerated() {
            let number = index + 1
            let stripped = stripComment(raw)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let leading = stripped.prefix { $0 == " " || $0 == "\t" }
            if leading.contains("\t") { throw ConfigError(line: number, message: "Tabs are not allowed for indentation.") }
            if trimmed == "---" || trimmed == "..." { throw ConfigError(line: number, message: "Document markers are not supported.") }
            result.append(Line(number: number, indent: leading.count, text: trimmed))
        }
        return result
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var escaped = false
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if open == "\"", character == "\\", !escaped { escaped = true; continue }
                if character == open, !escaped { quote = nil }
                escaped = false
            } else if (character == "\"" || character == "'"), previous == " " || previous == "[" || previous == "," || previous == ":" || offset == 0 {
                quote = character
            } else if character == "#", previous == " " || offset == 0 {
                return String(line.prefix(offset))
            }
            previous = character
        }
        return line
    }

    private struct Parser {
        var lines: [Line]
        var position = 0

        init(lines: [Line]) { self.lines = lines }

        private func isDash(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        mutating func block(indent: Int) throws -> Node {
            let line = lines[position]
            guard line.indent == indent else { throw ConfigError(line: line.number, message: "Unexpected indentation.") }
            return isDash(line.text) ? try list(indent: indent) : try map(indent: indent)
        }

        private mutating func list(indent: Int) throws -> Node {
            let first = lines[position].number
            var items: [Node] = []
            while position < lines.count, lines[position].indent == indent {
                let line = lines[position]
                guard isDash(line.text) else { throw ConfigError(line: line.number, message: "Expected a list item starting with '-'.") }
                let rest = String(line.text.dropFirst()).drop { $0 == " " }
                let dashWidth = line.text.count - rest.count
                if rest.isEmpty {
                    position += 1
                    guard position < lines.count, lines[position].indent > indent else {
                        throw ConfigError(line: line.number, message: "Empty list item.")
                    }
                    items.append(try block(indent: lines[position].indent))
                } else if ConfigSyntax.splitKey(String(rest)) != nil {
                    lines[position] = Line(number: line.number, indent: indent + dashWidth, text: String(rest))
                    items.append(try map(indent: indent + dashWidth))
                } else {
                    position += 1
                    items.append(try ConfigSyntax.value(String(rest), line: line.number))
                }
            }
            try finish(indent: indent)
            return .list(items, first)
        }

        private mutating func map(indent: Int) throws -> Node {
            let first = lines[position].number
            var entries: [Entry] = []
            while position < lines.count, lines[position].indent == indent {
                let line = lines[position]
                guard !isDash(line.text) else { throw ConfigError(line: line.number, message: "Unexpected list item; expected 'key: value'.") }
                guard let (key, rest) = ConfigSyntax.splitKey(line.text) else {
                    throw ConfigError(line: line.number, message: "Expected 'key: value'.")
                }
                if entries.contains(where: { $0.key == key }) {
                    throw ConfigError(line: line.number, message: "Duplicate key '\(key)'.")
                }
                position += 1
                let node: Node
                if !rest.isEmpty {
                    node = try ConfigSyntax.value(rest, line: line.number)
                } else if position < lines.count, lines[position].indent > indent {
                    node = try block(indent: lines[position].indent)
                } else if position < lines.count, lines[position].indent == indent, isDash(lines[position].text) {
                    node = try list(indent: indent)
                } else {
                    throw ConfigError(line: line.number, message: "Key '\(key)' has no value.")
                }
                entries.append(Entry(key: key, value: node, line: line.number))
            }
            try finish(indent: indent)
            return .map(entries, first)
        }

        private func finish(indent: Int) throws {
            if position < lines.count, lines[position].indent > indent {
                throw ConfigError(line: lines[position].number, message: "Unexpected indentation.")
            }
        }
    }

    /// Splits `key: rest` at the first colon outside quotes that is followed by a space or end of line.
    fileprivate static func splitKey(_ text: String) -> (String, String)? {
        var quote: Character?
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if open == "\"", character == "\\" { index += 2; continue }
                if character == open { quote = nil }
            } else if (character == "\"" || character == "'"), index == 0 {
                quote = character
            } else if character == ":", index + 1 == characters.count || characters[index + 1] == " " {
                let key = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, let unquoted = try? scalarText(key, line: 0) else { return nil }
                return (unquoted, rest)
            } else if character == "[" || character == "{" {
                return nil
            }
            index += 1
        }
        return nil
    }

    fileprivate static func value(_ text: String, line: Int) throws -> Node {
        if text.hasPrefix("{") { throw ConfigError(line: line, message: "Inline mappings are not supported; use an indented block.") }
        guard text.hasPrefix("[") else { return .scalar(try scalarText(text, line: line), line) }
        guard text.hasSuffix("]") else { throw ConfigError(line: line, message: "Unterminated inline list.") }
        let inner = String(text.dropFirst().dropLast())
        var items: [Node] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in inner {
            if let open = quote {
                current.append(character)
                if open == "\"", character == "\\", !escaped { escaped = true; continue }
                if character == open, !escaped { quote = nil }
                escaped = false
            } else if character == "\"" || character == "'", current.trimmingCharacters(in: .whitespaces).isEmpty {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(.scalar(try scalarText(current.trimmingCharacters(in: .whitespaces), line: line), line))
                current = ""
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { items.append(.scalar(try scalarText(last, line: line), line)) }
        return .list(items, line)
    }

    fileprivate static func scalarText(_ text: String, line: Int) throws -> String {
        guard let first = text.first else { throw ConfigError(line: line, message: "Empty value.") }
        if first == "\"" {
            guard text.count >= 2, text.hasSuffix("\"") else { throw ConfigError(line: line, message: "Unterminated quoted string.") }
            var result = ""
            var iterator = text.dropFirst().dropLast().makeIterator()
            while let character = iterator.next() {
                if character == "\\" {
                    guard let next = iterator.next(), next == "\"" || next == "\\" else {
                        throw ConfigError(line: line, message: "Only \\\" and \\\\ escapes are supported.")
                    }
                    result.append(next)
                } else if character == "\"" {
                    throw ConfigError(line: line, message: "Unescaped quote inside quoted string.")
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if first == "'" {
            guard text.count >= 2, text.hasSuffix("'") else { throw ConfigError(line: line, message: "Unterminated quoted string.") }
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if "&*!|>%@`".contains(first) {
            throw ConfigError(line: line, message: "Unquoted values cannot start with '\(first)'; wrap the value in quotes.")
        }
        return text
    }
}
