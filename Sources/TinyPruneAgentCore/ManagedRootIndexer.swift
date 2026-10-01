import Foundation
import CoreServices
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

private final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        let shouldWait = lock.withLock {
            if locked { return true }
            locked = true
            return false
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let wasEnqueued = lock.withLock {
                if !locked {
                    locked = true
                    return false
                }
                waiters.append(continuation)
                return true
            }
            if !wasEnqueued { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !waiters.isEmpty else {
                locked = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

private final class RootAccessToken: @unchecked Sendable {
    let url: URL
    private let securityScopeStarted: Bool

    init(url: URL) {
        self.url = url
        self.securityScopeStarted = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if securityScopeStarted { url.stopAccessingSecurityScopedResource() }
    }
}

private struct RootWatchSession: Sendable {
    let root: ManagedRoot
    let access: RootAccessToken
    let eventStream: ManagedRootEventStream
    let continuation: AsyncStream<ManagedRootEvent>.Continuation
    let consumer: Task<Void, Never>
}

public actor ManagedRootIndexer {
    private let store: SQLiteSafetyStore
    private let fileAccess: LocalTrashFileAccess
    private let fileManager: FileManager
    private let onDeadlinesChanged: @Sendable () -> Void
    private var sessions: [UUID: RootWatchSession] = [:]
    private let operationLock = AsyncMutex()

    private var recoveryRequests: Set<UUID> = []
    public init(
        store: SQLiteSafetyStore,
        fileAccess: LocalTrashFileAccess = LocalTrashFileAccess(),
        fileManager: FileManager = .default,
        onDeadlinesChanged: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.fileAccess = fileAccess
        self.fileManager = fileManager
        self.onDeadlinesChanged = onDeadlinesChanged
    }

    public func start() async throws {
        try await reconfigure()
    }

    public func stop() async {
        await operationLock.acquire()
        defer { operationLock.release() }
        stopSessions()
    }

    private func stopSessions() {
        for session in sessions.values {
            session.consumer.cancel()
            session.continuation.finish()
            session.eventStream.stop()
        }
        sessions.removeAll(keepingCapacity: false)
    }

    public func reconfigure() async throws {
        await operationLock.acquire()
        defer { operationLock.release() }
        let snapshot = try await store.loadSnapshot()
        let retainedPaths = Set(snapshot.managedRoots.map(\.path))
        let previousRoots = sessions.values.map(\.root)
        stopSessions()
        for root in previousRoots where !retainedPaths.contains(root.path) {
            try await store.removeDeadlines(atOrBelow: root.path)
        }

        for root in snapshot.managedRoots {
            try await store.removeDeadlines(atOrBelow: root.path)
            do { try await startWatching(root, snapshot: snapshot) }
            catch { await recordIndexFailure(root: root, error: error) }
        }
        onDeadlinesChanged()
    }

    public func processChanges(_ event: ManagedRootEvent, for rootID: UUID) async throws {
        await operationLock.acquire()
        defer { operationLock.release() }
        guard let session = sessions[rootID] else { return }
        let flags = event.flags
        let recoveryMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        let requiresRecovery = flags.contains { ($0 & recoveryMask) != 0 }
        if requiresRecovery {
            let snapshot = try await store.loadSnapshot()
            try await scan(session.access.url, root: session.root, snapshot: snapshot, includeRoot: false)
            onDeadlinesChanged()
            return
        }

        let snapshot = try await store.loadSnapshot()
        for (eventIndex, path) in event.paths.enumerated() {
            guard isWithinManagedRoot(path, rootPath: session.root.path) else { continue }
            let eventFlags = flags[eventIndex]
            if eventFlags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                try await store.removeDeadlines(atOrBelow: path)
                continue
            }
            if eventFlags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try await scan(directory, root: session.root, snapshot: snapshot, includeRoot: path != session.root.path)
            } else {
                try await store.removeDeadlines(atOrBelow: path)
                if let candidate = try await fileAccess.inspect(path: path) {
                    try await index(candidate, snapshot: snapshot)
                }
            }
        }
        onDeadlinesChanged()
    }

    private func startWatching(_ root: ManagedRoot, snapshot: PolicySnapshot) async throws {
        var stale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: root.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale, RuleScope.normalized(resolvedURL.path) == root.path else {
            throw ManagedRootIndexError.staleOrMovedBookmark(root.path)
        }
        let access = RootAccessToken(url: resolvedURL)
        let (events, continuation) = AsyncStream<ManagedRootEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let stream = try ManagedRootEventStream(rootPath: resolvedURL.path) { [weak self] event in
            switch continuation.yield(event) {
            case .dropped:
                Task { await self?.recover(rootID: root.id) }
            case .enqueued, .terminated:
                break
            @unknown default:
                Task { await self?.recover(rootID: root.id) }
            }
        }
        let consumer = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                do { try await self?.processChanges(event, for: root.id) }
                catch { await self?.recordIndexFailure(root: root, error: error) }
            }
        }
        sessions[root.id] = RootWatchSession(root: root, access: access, eventStream: stream, continuation: continuation, consumer: consumer)
        try await scan(resolvedURL, root: root, snapshot: snapshot, includeRoot: false)
    }

    private func recover(rootID: UUID) async {
        guard recoveryRequests.insert(rootID).inserted else { return }
        await operationLock.acquire()
        defer {
            recoveryRequests.remove(rootID)
            operationLock.release()
        }
        guard let session = sessions[rootID] else { return }
        do {
            let snapshot = try await store.loadSnapshot()
            try await scan(session.access.url, root: session.root, snapshot: snapshot, includeRoot: false)
            onDeadlinesChanged()
        } catch {
            await recordIndexFailure(root: session.root, error: error)
        }
    }

    private func scan(_ url: URL, root: ManagedRoot, snapshot: PolicySnapshot, includeRoot: Bool) async throws {
        try await store.removeDeadlines(atOrBelow: url.path)
        var batch: [PersistedDeadline] = []
        batch.reserveCapacity(256)

        if includeRoot, let candidate = try await fileAccess.inspect(path: url.path),
           let deadline = scheduledDeadline(for: candidate, snapshot: snapshot) {
            batch.append(deadline)
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        while let childURL = enumerator.nextObject() as? URL {
            let isSymbolicLink = try childURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
            if isSymbolicLink {
                enumerator.skipDescendants()
                continue
            }
            guard let candidate = try await fileAccess.inspect(path: childURL.path),
                  let deadline = scheduledDeadline(for: candidate, snapshot: snapshot) else { continue }
            batch.append(deadline)
            if batch.count == 256 {
                try await store.saveDeadlines(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if let enumerationError { throw enumerationError }
        if !batch.isEmpty { try await store.saveDeadlines(batch) }
        onDeadlinesChanged()
    }

    private func index(_ candidate: RuleCandidate, snapshot: PolicySnapshot) async throws {
        guard let deadline = scheduledDeadline(for: candidate, snapshot: snapshot) else { return }
        try await store.saveDeadline(deadline)
    }

    private func scheduledDeadline(for candidate: RuleCandidate, snapshot: PolicySnapshot) -> PersistedDeadline? {
        guard case .scheduled(let explanation) = RuleResolver.resolve(
            candidate: candidate,
            rules: snapshot.rules,
            overrides: snapshot.overrides,
            globallyPaused: snapshot.globallyPaused
        ) else { return nil }
        return PersistedDeadline(identity: candidate.identity, scheduledAt: explanation.scheduledAt, explanation: explanation)
    }

    private func isWithinManagedRoot(_ path: String, rootPath: String) -> Bool {
        let candidatePath = RuleScope.normalized(path)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func recordIndexFailure(root: ManagedRoot, error: Error) async {
        try? await store.append(TrashAuditEvent(
            occurredAt: Date(),
            kind: .safetySkipped,
            detail: "Indexing root \(root.path) stopped safely: \(error)"
        ))
    }
}

public enum ManagedRootIndexError: Error, Equatable, Sendable {
    case staleOrMovedBookmark(String)
}
