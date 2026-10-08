import Foundation

/// The single definition of "broad" scopes. UI, agent and CLI must use these instead of local heuristics.
public extension RuleScope {
    /// True when `path` is a location where a recursive rule could reach most of a user's or the system's
    /// data: `/`, `/Users`, any user home, `~/Library`, `/Volumes`, a volume root, `/private`,
    /// `/Applications` and the system directories. Compared case-insensitively, after normalization and
    /// after resolving symlinks (so `/tmp`-style aliases and case variants cannot slip through).
    static func isVeryBroad(path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        for candidate in Self.comparisonForms(of: path) where Self.isVeryBroadLowercased(candidate) {
            return true
        }
        return false
    }

    var isVeryBroad: Bool { Self.isVeryBroad(path: path) }

    /// Standardized path with symlinks resolved via `realpath`. Nonexistent tails are appended verbatim to
    /// the deepest existing ancestor.
    static func canonicalPath(_ path: String) -> String {
        let normalized = normalized(path)
        var existing = normalized
        var tail: [String] = []
        while existing != "/" {
            if let resolved = realpathString(existing) {
                return tail.reversed().reduce(resolved) { ($0 == "/" ? "" : $0) + "/" + $1 }
            }
            tail.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        return normalized
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Lowercased lexical and canonical spellings of `path` (deduplicated).
    internal static func comparisonForms(of path: String) -> [String] {
        let lexical = normalized(path).lowercased()
        let canonical = canonicalPath(path).lowercased()
        return lexical == canonical ? [lexical] : [lexical, canonical]
    }

    private static func homeDirectories() -> [String] {
        var homes = [NSHomeDirectory(), FileManager.default.homeDirectoryForCurrentUser.path]
        homes += homes.map { canonicalPath($0) }
        var seen = Set<String>()
        return homes
            .map { normalized($0).lowercased() }
            .filter { $0 != "/" && seen.insert($0).inserted }
    }

    private static let veryBroadExact: Set<String> = [
        "/", "/users", "/volumes", "/private", "/private/var", "/private/etc", "/applications", "/system",
        "/library", "/usr", "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", "/dev",
    ]

    private static func isVeryBroadLowercased(_ path: String) -> Bool {
        if veryBroadExact.contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        // /Users/<name> (any home), /Users/<name>/Library, /Volumes/<name> (a mounted volume root).
        if parts.count == 2, parts[0] == "users" || parts[0] == "volumes" { return true }
        if parts.count == 3, parts[0] == "users", parts[2] == "library" { return true }
        for home in homeDirectories() where path == home || path == home + "/library" { return true }
        return false
    }
}

public extension LifetimeRule {
    /// The rule's scope is somewhere a recursive rule could reach most user data (see `RuleScope.isVeryBroad`).
    /// Very broad rules may only run in Preview; the agent rejects Active ones.
    var isVeryBroad: Bool { scope.isVeryBroad }

    /// Broad rules start in Preview and need explicit confirmation before activation: very broad scopes,
    /// rules that match every item under a recursive scope (no names and no globs), and rules that expire by
    /// project activity over a recursive scope (developer-style cleanup). Template-mode rules are not tied to
    /// their scope, so they count as recursive.
    var isBroad: Bool {
        if isVeryBroad { return true }
        let reachesDescendants: Bool
        switch matchMode {
        case .scoped: reachesDescendants = scope.recursive
        case .template: reachesDescendants = true
        case .exactPath, .itemSpecific: reachesDescendants = false
        }
        guard reachesDescendants else { return false }
        if matcher.exactNames.isEmpty && matcher.globPatterns.isEmpty { return true }
        return expiryBasis == .projectActivity
    }
}

public extension ManagedRoot {
    /// Allowed but flagged: the root is a home folder, `/Users`, `/Volumes`, a volume root, etc.
    var isVeryBroad: Bool { RuleScope.isVeryBroad(path: path) }
}
