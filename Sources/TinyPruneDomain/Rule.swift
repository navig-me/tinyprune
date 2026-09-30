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

public struct RuleScope: Hashable, Codable, Sendable {
    public let path: String
    public let recursive: Bool

    public init(path: String, recursive: Bool) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuleValidationError.emptyScope
        }
        self.path = path
        self.recursive = recursive
    }
}

public struct ItemMatcher: Hashable, Codable, Sendable {
    public let itemKind: ItemKind
    public let exactNames: Set<String>

    public init(itemKind: ItemKind, exactNames: Set<String>) throws {
        guard exactNames.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RuleValidationError.emptyExactName
        }
        self.itemKind = itemKind
        self.exactNames = exactNames
    }

    public func matches(name: String, kind: ItemKind) -> Bool {
        guard itemKind.accepts(kind) else { return false }
        return exactNames.isEmpty || exactNames.contains(name)
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

    public init(
        id: UUID = UUID(),
        name: String,
        scope: RuleScope,
        matcher: ItemMatcher,
        expiryBasis: ExpiryBasis,
        lifetime: RuleDuration,
        gracePeriod: RuleDuration? = nil,
        action: FolderAction,
        state: RuleState
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
    }
}

public enum RuleValidationError: Error, Equatable, Sendable {
    case invalidDuration
    case emptyScope
    case emptyExactName
    case emptyRuleName
}
