import Darwin
import Foundation
import TinyPruneDomain

public enum LocalFileAccessError: Error, Equatable, Sendable {
    case symbolicLink(String)
    case missingStableIdentity(String)
    case missingTrashResult(String)
    case filesystemIdentityChanged(String)
}

/// Uses metadata and filesystem identifiers only; it never opens candidate contents.
public final class LocalTrashFileAccess: TrashFileAccess, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(path: String) async throws -> RuleCandidate? {
        try inspectSynchronously(path: path)
    }

    public func hasSymbolicLinkAncestor(of path: String, below rootPath: String) async throws -> Bool {
        let root = RuleScope.normalized(rootPath)
        var current = (RuleScope.normalized(path) as NSString).deletingLastPathComponent
        // Walk from the item's parent up to (but excluding) the managed root. Anything not below the root fails closed.
        guard current.hasPrefix(root + "/") || current == root else { return true }
        while current != root, current.hasPrefix(root + "/") {
            var info = stat()
            guard lstat(current, &info) == 0 else { return true }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    public func hasProtectedDescendant(
        path: String,
        overrides: [ItemPolicyOverride],
        protectHiddenFiles: Bool,
        budget: DescendantWalkBudget
    ) async throws -> DescendantProtection {
        try hasProtectedDescendantSynchronously(path: path, overrides: overrides, protectHiddenFiles: protectHiddenFiles, budget: budget)
    }

    private func inspectSynchronously(path: String) throws -> RuleCandidate? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw LocalFileAccessError.symbolicLink(path)
        }
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw LocalFileAccessError.missingStableIdentity(path)
        }

        let volumeUUID = try URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeUUIDStringKey])
            .volumeUUIDString
            .flatMap(UUID.init(uuidString:))
        let created = attributes[.creationDate] as? Date
        let identity = FilesystemIdentity(
            volumeIdentifier: volumeUUID ?? Self.volumeIdentifier(deviceNumber: device),
            resourceIdentifier: Self.resourceIdentifier(inode: inode),
            pathHint: RuleScope.normalized(path),
            creationTime: created,
            isPersistent: volumeUUID != nil
        )
        let kind: ItemKind = attributes[.type] as? FileAttributeType == .typeDirectory ? .directory : .file
        let timestamps = CandidateTimestamps(
            created: created,
            modified: attributes[.modificationDate] as? Date
        )
        return RuleCandidate(
            identity: identity,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            timestamps: timestamps
        )
    }

    private static func resourceIdentifier(inode: UInt64) -> Data {
        withUnsafeBytes(of: inode.bigEndian) { Data($0) }
    }

    /// Decides whether trashing `path` whole would remove protected content. Fails toward protection: symlinks are
    /// not skipped, enumeration errors surface as thrown errors, and a walk that exhausts its budget is
    /// `.indeterminate` (the caller must not trash).
    private func hasProtectedDescendantSynchronously(
        path: String,
        overrides: [ItemPolicyOverride],
        protectHiddenFiles: Bool,
        budget: DescendantWalkBudget
    ) throws -> DescendantProtection {
        let rootPath = RuleScope.normalized(path)
        let keeps = overrides.filter { override in
            if case .keep = override.policy { return true }
            return false
        }
        // Path-addressed Keeps need no filesystem walk: the recorded path alone decides.
        for keep in keeps where RuleResolver.keepProtectsDescendant(
            of: rootPath, override: keep, childIdentity: nil, childPath: keep.path
        ) {
            return .protected
        }
        // Without identity-addressed Keeps or hidden protection there is nothing a walk could find.
        let identityKeeps = keeps.filter { $0.identity != nil }
        guard !identityKeeps.isEmpty || protectHiddenFiles else { return .none }
        let keptInodes = Set(identityKeeps.compactMap { $0.identity?.resourceIdentifier })

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                if enumerationError == nil { enumerationError = error }
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var visited = 0
        while let childURL = enumerator.nextObject() as? URL {
            visited += 1
            if visited > budget.maxEntries { return .indeterminate }
            if visited % 256 == 0, budget.clock.now() >= budget.deadline { return .indeterminate }
            let childPath = RuleScope.normalized(childURL.path)

            if protectHiddenFiles, ItemMatcher.isHiddenName(childURL.lastPathComponent) {
                return .protected
            }
            guard !keptInodes.isEmpty else { continue }
            var info = stat()
            guard lstat(childPath, &info) == 0 else { continue }
            guard keptInodes.contains(Self.resourceIdentifier(inode: UInt64(info.st_ino))) else { continue }
            // Inode alone is not an identity: confirm volume and creation time before treating it as the kept item.
            let isSymbolicLink = (info.st_mode & S_IFMT) == S_IFLNK
            let childIdentity: FilesystemIdentity?
            if isSymbolicLink {
                childIdentity = try linkIdentity(path: childPath, info: info)
            } else {
                childIdentity = try inspectSynchronously(path: childPath)?.identity
            }
            for keep in identityKeeps where RuleResolver.keepProtectsDescendant(
                of: rootPath, override: keep, childIdentity: childIdentity, childPath: childPath
            ) {
                return .protected
            }
        }
        if let enumerationError { throw enumerationError }
        return .none
    }

    /// Identity of a symbolic link itself (never its target), used to fail closed on links that match a Keep.
    private func linkIdentity(path: String, info: stat) throws -> FilesystemIdentity {
        let volumeUUID = try URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeUUIDStringKey])
            .volumeUUIDString
            .flatMap(UUID.init(uuidString:))
        return FilesystemIdentity(
            volumeIdentifier: volumeUUID ?? Self.volumeIdentifier(deviceNumber: UInt64(UInt32(bitPattern: info.st_dev))),
            resourceIdentifier: Self.resourceIdentifier(inode: UInt64(info.st_ino)),
            pathHint: path,
            isPersistent: volumeUUID != nil
        )
    }

    public func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String {
        let url = URL(fileURLWithPath: path)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var trashedPath: String?

        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                guard let current = try inspectSynchronously(path: coordinatedURL.path),
                      current.identity == expectedIdentity else {
                    throw LocalFileAccessError.filesystemIdentityChanged(path)
                }
                var trashedURL: NSURL?
                try fileManager.trashItem(at: coordinatedURL, resultingItemURL: &trashedURL)
                trashedPath = trashedURL?.path
            } catch {
                operationError = error
            }
        }

        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard let trashedPath else { throw LocalFileAccessError.missingTrashResult(path) }
        return trashedPath
    }

    private static func volumeIdentifier(deviceNumber: UInt64) -> UUID {
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: deviceNumber >> (56 - 8 * $0)) }
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]))
    }
}
