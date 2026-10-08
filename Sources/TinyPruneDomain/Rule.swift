import Foundation

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case file
    case directory
    case fileOrDirectory

    public func accepts(_ candidate: ItemKind) -> Bool {
        self == .fileOrDirectory || self == candidate
    }
}

public enum RuleState: String, Codable, CaseIterable, Sendable {
    case preview
    case active
    case paused
}

public enum ExpiryBasis: String, Codable, CaseIterable, Sendable {
    case created
    case modified
    case firstObserved
    case observedActivity
    case accessed
    case projectActivity
    case explicitDate
}

public enum FolderAction: String, Codable, CaseIterable, Sendable {
    case trashItem
    case emptyContents
    case trashMatchingChildren
}

public struct RuleDuration: Hashable, Codable, Sendable, Comparable {
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0 else {
            throw RuleValidationError.invalidDuration
        }
        self.seconds = seconds
    }

    public static func < (lhs: RuleDuration, rhs: RuleDuration) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

public enum RuleMatchMode: String, Codable, Sendable, Hashable {
    case scoped
    case exactPath
    case itemSpecific
    case template
}

public struct RuleScope: Hashable, Codable, Sendable {
    public let path: String
    public let recursive: Bool

    public init(path: String, recursive: Bool) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.hasPrefix("/") else { throw RuleValidationError.invalidScope }
        let normalizedPath = Self.normalized(path)
        guard normalizedPath != "/" else { throw RuleValidationError.invalidScope }
        self.path = normalizedPath
        self.recursive = recursive
    }

    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public func relativePath(of candidatePath: String) -> String? {
        let candidate = Self.normalized(candidatePath)
        guard candidate != path, candidate.hasPrefix(path + "/") else { return nil }
        let relative = String(candidate.dropFirst(path.count + 1))
        guard recursive || !relative.contains("/") else { return nil }
        return relative
    }
}

public struct ItemMatcher: Hashable, Codable, Sendable {
    public let itemKind: ItemKind
    public let exactNames: Set<String>
    public let globPatterns: Set<String>
    private let compiledGlobPatterns: [GlobPattern]

    public init(itemKind: ItemKind, exactNames: Set<String>, globPatterns: Set<String> = []) throws {
        guard exactNames.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              globPatterns.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RuleValidationError.emptyMatcherPattern
        }
        self.itemKind = itemKind
        self.exactNames = exactNames
        self.globPatterns = globPatterns
        self.compiledGlobPatterns = globPatterns.sorted().map(GlobPattern.init)
    }

    private enum CodingKeys: String, CodingKey { case itemKind, exactNames, globPatterns }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemKind: container.decode(ItemKind.self, forKey: .itemKind),
            exactNames: container.decode(Set<String>.self, forKey: .exactNames),
            globPatterns: container.decodeIfPresent(Set<String>.self, forKey: .globPatterns) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemKind, forKey: .itemKind)
        try container.encode(exactNames.sorted(), forKey: .exactNames)
        try container.encode(globPatterns.sorted(), forKey: .globPatterns)
    }

    public func matches(name: String, relativePath: String, kind: ItemKind) -> Bool {
        specificity(name: name, relativePath: relativePath, kind: kind) != nil
    }

    func specificity(name: String, relativePath: String, kind: ItemKind) -> Int? {
        guard itemKind.accepts(kind) else { return nil }
        if exactNames.contains(name) { return 2 }
        if compiledGlobPatterns.contains(where: { $0.matches(name: name, relativePath: relativePath) }) { return 1 }
        if exactNames.isEmpty && compiledGlobPatterns.isEmpty { return 0 }
        return nil
    }
}

public struct LifetimeRule: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let scope: RuleScope
    public let matcher: ItemMatcher
    public let expiryBasis: ExpiryBasis
    public let lifetime: RuleDuration
    public let gracePeriod: RuleDuration?
    public let action: FolderAction
    public let state: RuleState
    public let matchMode: RuleMatchMode

    public init(
        id: UUID = UUID(),
        name: String,
        scope: RuleScope,
        matcher: ItemMatcher,
        expiryBasis: ExpiryBasis,
        lifetime: RuleDuration,
        gracePeriod: RuleDuration? = nil,
        action: FolderAction,
        state: RuleState,
        matchMode: RuleMatchMode = .scoped
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuleValidationError.emptyRuleName
        }
        self.id = id
        self.name = name
        self.scope = scope
        self.matcher = matcher
        self.expiryBasis = expiryBasis
        self.lifetime = lifetime
        self.gracePeriod = gracePeriod
        self.action = action
        self.state = state
        self.matchMode = matchMode
    }
}

/// Glob matching with gitignore-style semantics.
///
/// Supported: `*` (any run of characters except `/`), `?` (one character except `/`), `**/` (zero or more
/// directories), a trailing `**` (anything, including `/`). A pattern WITHOUT a `/` matches the item's
/// basename at any depth (like `.gitignore`); a pattern WITH a `/` is anchored to the scope root and matched
/// against the scope-relative path (a single leading `/` is allowed and ignored).
///
/// NOT supported (treated as literal characters): character classes `[abc]`, brace alternation `{a,b}`,
/// `!` negation, backslash escapes, and trailing-`/` directory-only markers (use the rule's item kind instead).
public struct GlobPattern: Hashable, @unchecked Sendable {
    public let pattern: String
    private let expression: NSRegularExpression?
    /// True when the pattern has no `/` and therefore matches by basename at any depth.
    public let matchesBasename: Bool

    public init(_ pattern: String) {
        self.pattern = pattern
        let anchored = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        self.matchesBasename = !pattern.contains("/")
        self.expression = try? NSRegularExpression(pattern: Self.regex(for: anchored), options: [.dotMatchesLineSeparators])
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.pattern == rhs.pattern }

    public func hash(into hasher: inout Hasher) { hasher.combine(pattern) }

    /// Literal match of `value` against the whole pattern (no basename-at-any-depth behavior).
    public func matches(_ value: String) -> Bool {
        guard let expression else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    /// Item-level match: basename patterns test `name`; patterns containing `/` test `relativePath`.
    public func matches(name: String, relativePath: String) -> Bool {
        matches(matchesBasename ? name : relativePath)
    }

    private static func regex(for pattern: String) -> String {
        let characters = Array(pattern)
        var result = "\\A"
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        result += "(?:.*/)?"
                        index += 2
                    } else {
                        result += ".*"
                        index += 1
                    }
                } else {
                    result += "[^/]*"
                }
            case "?": result += "[^/]"
            default: result += NSRegularExpression.escapedPattern(for: String(characters[index]))
            }
            index += 1
        }
        return result + "\\z"
    }
}

public enum RuleValidationError: Error, Equatable, Sendable {
    case invalidDuration
    case invalidScope
    case emptyMatcherPattern
    case emptyRuleName
}
