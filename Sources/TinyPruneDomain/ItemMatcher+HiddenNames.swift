import Foundation

public extension ItemMatcher {
    /// The single definition of a hidden item name (leading dot). The engine uses it to protect hidden
    /// descendants of a folder that would otherwise be trashed whole.
    static func isHiddenName(_ name: String) -> Bool {
        name.hasPrefix(".")
    }

    /// True when any component of a `/`-separated path is hidden.
    static func hasHiddenComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { isHiddenName(String($0)) }
    }
}

extension ItemMatcher {
    /// True when the matcher names a dot-item on purpose: an exact name starting with `.`, or a glob whose
    /// final path component starts with `.`. Such rules are exempt from hidden-file protection.
    var explicitlyTargetsDotName: Bool {
        if exactNames.contains(where: { $0.hasPrefix(".") }) { return true }
        return globPatterns.contains { pattern in
            let last = pattern.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(pattern)
            return last.hasPrefix(".")
        }
    }
}
