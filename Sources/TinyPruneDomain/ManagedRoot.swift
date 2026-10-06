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
        let protectedLocations = ["/Applications", "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/var"]
        guard !normalizedPath.hasSuffix("/Library"),
              !protectedLocations.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) else {
            throw ManagedRootValidationError.dangerousPath
        }
        guard !bookmarkData.isEmpty else { throw ManagedRootValidationError.emptyBookmark }
        self.id = id
        self.displayName = displayName
        self.path = normalizedPath
        self.bookmarkData = bookmarkData
    }
}

public enum ManagedRootValidationError: Error, Equatable, Sendable {
    case emptyName
    case invalidPath
    case emptyBookmark
    case dangerousPath
}
