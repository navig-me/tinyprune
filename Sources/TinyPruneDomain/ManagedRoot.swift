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
}
