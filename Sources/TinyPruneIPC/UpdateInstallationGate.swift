import Darwin
import Dispatch
import Foundation

/// Coordinates the updater with every agent Trash operation, including across process exits.
/// The durable marker remains after the app releases its lock during replacement; failures close the gate.
public final class UpdateInstallationGate: @unchecked Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TinyPrune", isDirectory: true)
    private let directory: URL
    private let mutex = NSLock()
    private var installationDescriptor: Int32 = -1

    private struct Installation: Codable {
        let sourceVersion: String
        let targetVersion: String
    }

    public init(directory: URL = defaultDirectory) { self.directory = directory }

    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) throws -> UpdateInstallationObservation {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try UpdateInstallationObservation(directory: directory, onChange: onChange)
    }

    public func hasPendingInstallation() throws -> Bool { try markerExists() }
    deinit {
        if installationDescriptor >= 0 { close(installationDescriptor) }
    }

    /// A permit must remain alive throughout preflight, move, and outcome audit.
    public func acquireTrashPermit() throws -> UpdateTrashPermit? {
        let descriptor = try openLock()
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        do {
            if try markerExists() { close(descriptor); return nil }
            return UpdateTrashPermit(descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Nonblocking: an in-flight Trash operation rejects installation rather than interrupting it.
    public func beginInstallation(targetVersion: String, currentVersion: String) throws {
        mutex.lock()
        defer { mutex.unlock() }
        if installationDescriptor >= 0 {
            let marker = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: markerURL))
            guard marker.targetVersion == targetVersion, marker.sourceVersion == currentVersion else {
                throw UpdateInstallationError.recoveryRequired
            }
            return
        }
        guard !targetVersion.isEmpty, !currentVersion.isEmpty, targetVersion != currentVersion else {
            throw UpdateInstallationError.invalidVersion
        }
        let descriptor = try exclusiveLock()
        do {
            guard try !markerExists() else { throw UpdateInstallationError.recoveryRequired }
            let marker = Installation(sourceVersion: currentVersion, targetVersion: targetVersion)
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            try syncMarkerToDisk()
            installationDescriptor = descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Reclaim the lock before Sparkle may resume a previously downloaded installation.
    /// This never reopens cleanup: the durable marker stays in place until install or cancellation.
    @discardableResult
    public func resumePendingInstallation(currentVersion: String) throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard installationDescriptor < 0 else { return true }
        guard try markerExists() else { return false }
        let descriptor = try exclusiveLock()
        do {
            let marker = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: markerURL))
            guard marker.sourceVersion == currentVersion, marker.targetVersion != currentVersion else {
                throw UpdateInstallationError.recoveryRequired
            }
            installationDescriptor = descriptor
            return true
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Only the original updater may cancel its own installation marker.
    /// The marker is removed while the exclusive lock is still held, so a failed removal leaves the
    /// gate retryable (descriptor kept) instead of wedged with a marker nobody owns.
    public func finishInstallation() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard installationDescriptor >= 0 else { return }
        try removeMarkerIfPresent()
        close(installationDescriptor)
        installationDescriptor = -1
        signalChange()
    }

    /// A launch of the unchanged old app cannot reopen cleanup during replacement.
    @discardableResult
    public func recoverCompletedInstallation(
        currentVersion: String,
        beforeResuming: () throws -> Void = {}
    ) throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard installationDescriptor < 0 else { return false }
        guard try markerExists() else { return false }
        var descriptor = try exclusiveLock()
        defer { if descriptor >= 0 { close(descriptor) } }
        guard try markerExists() else { return false }
        let marker = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: markerURL))
        guard marker.targetVersion == currentVersion, marker.sourceVersion != currentVersion else {
            throw UpdateInstallationError.recoveryRequired
        }
        try beforeResuming()
        try removeMarkerIfPresent()
        close(descriptor)
        descriptor = -1
        signalChange()
        return true
    }

    private func removeMarkerIfPresent() throws {
        do { try FileManager.default.removeItem(at: markerURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
    }

    /// Observers wake on directory changes. Marker removal happens while the lock is still held, so
    /// emit one more directory event after the lock is released for waiters that raced it.
    private func signalChange() {
        let wake = directory.appendingPathComponent("update-installation.wake")
        if (try? Data().write(to: wake)) != nil { try? FileManager.default.removeItem(at: wake) }
    }

    private var markerURL: URL { directory.appendingPathComponent("update-installation.json") }


    private func markerExists() throws -> Bool {
        var metadata = stat()
        if lstat(markerURL.path, &metadata) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func syncMarkerToDisk() throws {
        for url in [markerURL, directory] {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let result = fsync(descriptor)
            let error = errno
            close(descriptor)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        }
    }

    private func exclusiveLock() throws -> Int32 {
        let descriptor = try openLock()
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { throw UpdateInstallationError.cleanupInProgress }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return descriptor
    }

    private func openLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("update-installation.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }
}

public final class UpdateTrashPermit: @unchecked Sendable {
    private let descriptor: Int32
    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
}

public enum UpdateInstallationError: Error, LocalizedError, Equatable, Sendable {
    case cleanupInProgress, invalidVersion, recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .cleanupInProgress: "Cleanup is currently running. Try the update again after it finishes."
        case .invalidVersion: "The update does not identify a different app version."
        case .recoveryRequired: "Cleanup is suspended after an interrupted update. Resume the pending update or manually install its intended target version before cleanup can resume."
        }
    }
}

public final class UpdateInstallationObservation: @unchecked Sendable {
    private let source: any DispatchSourceFileSystemObject

    fileprivate init(directory: URL, onChange: @escaping @Sendable () -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.activate()
    }

    deinit { source.cancel() }
}
