import Foundation

public struct ManagedRoot: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let path: String
    public let bookmarkData: Data

    public init(id: UUID = UUID(), displayName: String, path: String, bookmarkData: Data) throws {
        let normalizedPath = RuleScope.normalized(path)
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagedRootValidationError.emptyName
        }
        guard path.hasPrefix("/"), normalizedPath != "/", path == normalizedPath else {
            throw ManagedRootValidationError.invalidPath
        }
        guard !Self.isDangerous(path: normalizedPath) else {
            throw ManagedRootValidationError.dangerousPath
        }
        guard !bookmarkData.isEmpty else { throw ManagedRootValidationError.emptyBookmark }
        self.id = id
        self.displayName = displayName
        self.path = normalizedPath
        self.bookmarkData = bookmarkData
    }

    private static let protectedLocations = [
        "/applications", "/system", "/library", "/bin", "/sbin", "/usr", "/etc", "/var",
        "/private/etc", "/private/var/db", "/dev", "/cores",
    ]

    /// Case-insensitive, checked on both the normalized path and its symlink-resolved form so aliases like
    /// `/applications` or a symlink into `/System` cannot bypass the denylist.
    static func isDangerous(path: String) -> Bool {
        RuleScope.comparisonForms(of: path).contains { form in
            form.hasSuffix("/library")
                || protectedLocations.contains { form == $0 || form.hasPrefix($0 + "/") }
        }
    }
}

public enum ManagedRootValidationError: Error, Equatable, Sendable {
    case emptyName
    case invalidPath
    case emptyBookmark
    case dangerousPath
}
