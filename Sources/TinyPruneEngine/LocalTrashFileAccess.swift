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

    public func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride]) async throws -> Bool {
        try hasProtectedDescendantSynchronously(path: path, overrides: overrides)
    }

    private func inspectSynchronously(path: String) throws -> RuleCandidate? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: path)
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
        let identity = FilesystemIdentity(
            volumeIdentifier: volumeUUID ?? Self.volumeIdentifier(deviceNumber: device),
            resourceIdentifier: withUnsafeBytes(of: inode.bigEndian) { Data($0) },
            pathHint: RuleScope.normalized(path)
        )
        let kind: ItemKind = attributes[.type] as? FileAttributeType == .typeDirectory ? .directory : .file
        let timestamps = CandidateTimestamps(
            created: attributes[.creationDate] as? Date,
            modified: attributes[.modificationDate] as? Date
        )
        return RuleCandidate(
            identity: identity,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            timestamps: timestamps
        )
    }

    private func hasProtectedDescendantSynchronously(path: String, overrides: [ItemPolicyOverride]) throws -> Bool {
        let rootPath = RuleScope.normalized(path)
        let identityKeepOverrides = overrides.filter { override in
            guard override.identity != nil else { return false }
            if case .keep = override.policy { return true }
            return false
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        for case let childURL as URL in enumerator {
            let childPath = RuleScope.normalized(childURL.path)
            let isSymbolicLink = try childURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
            guard !isSymbolicLink else {
                continue
            }
            if !identityKeepOverrides.isEmpty,
               let child = try inspectSynchronously(path: childPath),
               identityKeepOverrides.contains(where: { $0.identity == child.identity }) {
                return true
            }
            for override in overrides {
                guard override.identity == nil,
                      case .keep(let protectDescendants) = override.policy else { continue }
                if childPath == override.path || (protectDescendants && childPath.hasPrefix(override.path + "/")) {
                    return true
                }
            }
        }
        if let enumerationError { throw enumerationError }
        return false
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
