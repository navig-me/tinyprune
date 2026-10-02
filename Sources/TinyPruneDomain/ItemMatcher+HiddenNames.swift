import Foundation

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
