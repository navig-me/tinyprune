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
    let initialScan: Task<Void, Never>?
}

public actor ManagedRootIndexer {
    private let store: SQLiteSafetyStore
    private let fileAccess: LocalTrashFileAccess
    private let fileManager: FileManager
    private let clock: any SafetyClock
    private let onDeadlinesChanged: @Sendable () -> Void
    private var sessions: [UUID: RootWatchSession] = [:]
    private let operationLock = AsyncMutex()

    private var recoveryRequests: Set<UUID> = []
    public init(
        store: SQLiteSafetyStore,
        fileAccess: LocalTrashFileAccess = LocalTrashFileAccess(),
        fileManager: FileManager = .default,
        clock: any SafetyClock = SystemSafetyClock(),
        onDeadlinesChanged: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.fileAccess = fileAccess
        self.fileManager = fileManager
        self.clock = clock
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
            session.initialScan?.cancel()
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
            try await store.removeObservedActivity(atOrBelow: root.path)
        }

        for root in snapshot.managedRoots {
            try await store.removeDeadlines(atOrBelow: root.path)
            do { try await startWatching(root) }
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
                try await store.removeObservedActivity(atOrBelow: path)
                continue
            }
            if eventFlags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try await scan(directory, root: session.root, snapshot: snapshot, includeRoot: path != session.root.path)
                if path != session.root.path, let candidate = try await fileAccess.inspect(path: path) {
                    try await index(candidate, snapshot: snapshot, activityAt: clock.now())
                }
            } else {
                try await store.removeDeadlines(atOrBelow: path)
                if let candidate = try await fileAccess.inspect(path: path) {
                    try await index(candidate, snapshot: snapshot, activityAt: clock.now())
                }
            }
        }
        onDeadlinesChanged()
    }

    private func startWatching(_ root: ManagedRoot) async throws {
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
        let rootValues = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ManagedRootIndexError.unsafeRoot(root.path)
        }
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
        let session = RootWatchSession(root: root, access: access, eventStream: stream, continuation: continuation, consumer: consumer, initialScan: nil)
        sessions[root.id] = session
        let initialScan = Task { [weak self] in
            guard let self else { return }
            await self.scanRoot(rootID: root.id)
        }
        sessions[root.id] = RootWatchSession(root: root, access: access, eventStream: stream, continuation: continuation, consumer: consumer, initialScan: initialScan)
    }

    private func scanRoot(rootID: UUID) async {
        await operationLock.acquire()
        defer { operationLock.release() }
        guard !Task.isCancelled, let session = sessions[rootID] else { return }
        do {
            let snapshot = try await store.loadSnapshot()
            try await scan(session.access.url, root: session.root, snapshot: snapshot, includeRoot: false)
            onDeadlinesChanged()
        } catch {
            await recordIndexFailure(root: session.root, error: error)
        }

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
        var deadlineBatch: [PersistedDeadline] = []
        var activityBatch: [PersistedObservedActivity] = []
        deadlineBatch.reserveCapacity(256)
        activityBatch.reserveCapacity(256)
        let observationTime = clock.now()


        if includeRoot, let candidate = try await fileAccess.inspect(path: url.path) {
            let prepared = try await scheduledDeadline(for: candidate, snapshot: snapshot, initialObservationAt: observationTime)
            if let deadline = prepared.deadline { deadlineBatch.append(deadline) }
            if let activity = prepared.newActivity { activityBatch.append(activity) }
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
            guard let candidate = try await fileAccess.inspect(path: childURL.path) else { continue }
            let prepared = try await scheduledDeadline(for: candidate, snapshot: snapshot, initialObservationAt: observationTime)
            if let deadline = prepared.deadline { deadlineBatch.append(deadline) }
            if let activity = prepared.newActivity { activityBatch.append(activity) }
            if deadlineBatch.count == 256 || activityBatch.count == 256 {
                try await persistBatch(deadlines: deadlineBatch, activities: activityBatch)
                activityBatch.removeAll(keepingCapacity: true)
                deadlineBatch.removeAll(keepingCapacity: true)
            }
        }

        if let enumerationError { throw enumerationError }
        try await persistBatch(deadlines: deadlineBatch, activities: activityBatch)
        onDeadlinesChanged()
    }

    private func persistBatch(deadlines: [PersistedDeadline], activities: [PersistedObservedActivity]) async throws {
        try await store.recordInitialObservations(activities)
        try await store.saveDeadlines(deadlines)

    }
    private func index(_ candidate: RuleCandidate, snapshot: PolicySnapshot, activityAt date: Date) async throws {
        let prepared = try await scheduledDeadline(for: candidate, snapshot: snapshot, activityAt: date)
        if let deadline = prepared.deadline { try await store.saveDeadline(deadline) }
    }

    private func scheduledDeadline(
        for candidate: RuleCandidate,
        snapshot: PolicySnapshot,
        initialObservationAt: Date? = nil,
        activityAt: Date? = nil
    ) async throws -> (deadline: PersistedDeadline?, newActivity: PersistedObservedActivity?) {
        var evaluatedCandidate = candidate
        var newActivity: PersistedObservedActivity?
        if usesObservedActivity(candidate, rules: snapshot.rules) {
            let activity: PersistedObservedActivity
            if let activityAt {
                try await store.recordObservedActivity(identity: candidate.identity, at: activityAt)
                guard let recordedActivity = try await store.observedActivity(for: candidate.identity) else {
                    throw ManagedRootIndexError.observedActivityMissing(candidate.identity.pathHint)
                }
                activity = recordedActivity
            } else if let existing = try await store.observedActivity(for: candidate.identity) {
                activity = existing
            } else {
                let now = initialObservationAt ?? clock.now()
                activity = PersistedObservedActivity(identity: candidate.identity, firstObservedAt: now, lastObservedAt: now)
                newActivity = activity
            }
            let timestamps = candidate.timestamps
            evaluatedCandidate = RuleCandidate(
                identity: candidate.identity,
                name: candidate.name,
                kind: candidate.kind,
                timestamps: CandidateTimestamps(
                    created: timestamps.created,
                    modified: timestamps.modified,
                    firstObserved: activity.firstObservedAt,
                    observedActivity: activity.lastObservedAt,
                    accessed: timestamps.accessed,
                    projectActivity: timestamps.projectActivity,
                    explicitDate: timestamps.explicitDate
                )
            )
        }
        guard case .scheduled(let explanation) = RuleResolver.resolve(
            candidate: evaluatedCandidate,
            rules: snapshot.rules,
            overrides: snapshot.overrides,
            globallyPaused: snapshot.globallyPaused
        ) else { return (nil, newActivity) }
        return (PersistedDeadline(identity: candidate.identity, scheduledAt: explanation.scheduledAt, explanation: explanation), newActivity)
    }

    private func usesObservedActivity(_ candidate: RuleCandidate, rules: [LifetimeRule]) -> Bool {
        let candidatePath = RuleScope.normalized(candidate.identity.pathHint)
        return rules.contains { rule in
            guard rule.expiryBasis == .firstObserved || rule.expiryBasis == .observedActivity else { return false }
            let relativePath: String
            switch rule.matchMode {
            case .scoped:
                guard let relative = rule.scope.relativePath(of: candidatePath) else { return false }
                relativePath = relative
            case .exactPath, .itemSpecific:
                guard candidatePath == rule.scope.path else { return false }
                relativePath = candidate.name
            case .template:
                relativePath = candidate.name
            }
            return rule.matcher.matches(name: candidate.name, relativePath: relativePath, kind: candidate.kind)
        }
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
    case unsafeRoot(String)
    case observedActivityMissing(String)
}
