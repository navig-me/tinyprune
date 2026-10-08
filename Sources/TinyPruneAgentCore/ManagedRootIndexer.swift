import Foundation
import Darwin
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

final class RootAccessToken: @unchecked Sendable {
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

private final class RootRecoveryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var required = false

    var isRequired: Bool { lock.withLock { required } }
    func request() { lock.withLock { required = true } }
}

private struct RootWatchSession: Sendable {
    let root: ManagedRoot
    let access: RootAccessToken
    let eventStream: ManagedRootEventStream
    let continuation: AsyncStream<ManagedRootEvent>.Continuation
    let consumer: Task<Void, Never>
    let recoveryLatch: RootRecoveryLatch
    let initialScan: Task<Void, Never>?
}

private struct ScanBatch: Sendable {
    var projects: [PersistedProjectActivity] = []
    var sourceObservations: [ProjectActivityObservation] = []
    var deadlines: [PersistedDeadline] = []
    var observedActivity: [PersistedObservedActivity] = []
}

private final class ScanBatchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var batch = ScanBatch()

    func append(
        project: PersistedProjectActivity? = nil,
        sourceObservation: ProjectActivityObservation? = nil,
        deadline: PersistedDeadline? = nil,
        observedActivity: PersistedObservedActivity? = nil
    ) -> ScanBatch? {
        lock.withLock {
            if let project { batch.projects.append(project) }
            if let sourceObservation { batch.sourceObservations.append(sourceObservation) }
            if let deadline { batch.deadlines.append(deadline) }
            if let observedActivity { batch.observedActivity.append(observedActivity) }
            guard batch.projects.count >= 256 ||
                    batch.sourceObservations.count >= 256 ||
                    batch.deadlines.count >= 256 ||
                    batch.observedActivity.count >= 256 else { return nil }
            return takeLocked()
        }
    }

    func take() -> ScanBatch {
        lock.withLock { takeLocked() }
    }

    private func takeLocked() -> ScanBatch {
        let completed = batch
        batch = ScanBatch()
        return completed
    }
}

private struct RootStatusEntry: Sendable {
    var root: ManagedRoot
    var state: AgentRootState
    var detail: String?
}

public actor ManagedRootIndexer {
    /// Recoveries closer together than this count as one flood and back off exponentially.
    private static let recoveryFloodWindow: TimeInterval = 120
    private static let failureAuditInterval: TimeInterval = 60

    static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private let store: SQLiteSafetyStore
    private let fileAccess: LocalTrashFileAccess
    private let fileManager: FileManager
    private let clock: any SafetyClock
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let diagnosticsRecorder = ManagedRootDiagnosticsRecorder()
    private let onDeadlinesChanged: @Sendable () -> Void
    private let bookmarkResolver: (@Sendable (ManagedRoot) throws -> URL)?
    private var sessions: [UUID: RootWatchSession] = [:]
    private let operationLock = AsyncMutex()
    private var recoveryRequests: Set<UUID> = []
    private var statuses: [UUID: RootStatusEntry] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var lastRecovery: [UUID: (at: Date, streak: Int)] = [:]
    private var lastFailureAudit: [UUID: Date] = [:]

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
        self.sleep = Self.defaultSleep
        self.onDeadlinesChanged = onDeadlinesChanged
        self.bookmarkResolver = nil
    }

    init(
        store: SQLiteSafetyStore,
        resolver: @escaping @Sendable (ManagedRoot) throws -> URL,
        clock: any SafetyClock = SystemSafetyClock(),
        onDeadlinesChanged: @escaping @Sendable () -> Void = {},
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = ManagedRootIndexer.defaultSleep
    ) {
        self.store = store
        self.fileAccess = LocalTrashFileAccess()
        self.fileManager = .default
        self.clock = clock
        self.sleep = sleep
        self.onDeadlinesChanged = onDeadlinesChanged
        self.bookmarkResolver = resolver
    }

    public func diagnosticsSnapshot() -> ManagedRootDiagnosticsSnapshot {
        diagnosticsRecorder.snapshot()
    }

    /// Per-root health for the app: watching, indexing, recovering, offline, stale bookmark, denied, or failed.
    public func rootStatuses() -> [AgentRootStatus] {
        statuses.values
            .map { AgentRootStatus(rootID: $0.root.id, path: $0.root.path, state: $0.state, detail: $0.detail) }
            .sorted { $0.path < $1.path }
    }

    public func inspectManagedPath(_ path: String) async throws -> RuleCandidate? {
        let normalizedPath = RuleScope.normalized(path)
        guard sessions.values.contains(where: { session in
            let rootPath = RuleScope.normalized(session.access.url.path)
            return normalizedPath == rootPath || normalizedPath.hasPrefix(rootPath + "/")
        }) else { return nil }
        return try await inspectIfIndexable(normalizedPath)
    }

    /// Symlinks, vanished entries and entries without a stable identity are never indexed; they are not errors.
    private func inspectIfIndexable(_ path: String) async throws -> RuleCandidate? {
        do {
            return try await fileAccess.inspect(path: path)
        } catch let error as LocalFileAccessError {
            switch error {
            case .symbolicLink, .missingStableIdentity: return nil
            default: throw error
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func pathExistsWithoutFollowingSymlinks(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Reconcile only the subtrees under explicit override changes: a single item for files,
    /// one bounded-batch scan of the subtree for folders (descendant protection may have changed).
    func reconcileOverrides(paths: [String]) async throws {
        let normalized = Set(paths.map(RuleScope.normalized)).sorted()
        var topMost: [String] = []
        for path in normalized where !topMost.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            topMost.append(path)
        }
        guard !topMost.isEmpty else { return }
        await operationLock.acquire()
        defer { operationLock.release() }
        let snapshot = try await store.loadSnapshot()
        for path in topMost {
            try Task.checkCancellation()
            guard let session = sessions.values.first(where: { isWithinManagedRoot(path, rootPath: RuleScope.normalized($0.access.url.path)) }) else { continue }
            guard let candidate = try await inspectIfIndexable(path) else {
                try await store.removeDeadlines(atOrBelow: path)
                continue
            }
            if candidate.kind == .directory {
                try await scan(URL(fileURLWithPath: path, isDirectory: true), root: session.root, snapshot: snapshot, includeRoot: true)
            } else {
                let prepared = try await scheduledDeadline(for: candidate, snapshot: snapshot)
                try await store.removeDeadline(for: candidate.identity)
                try await persistBatch(deadlines: prepared.deadline.map { [$0] } ?? [], activities: prepared.newActivity.map { [$0] } ?? [])
            }
        }
        onDeadlinesChanged()
    }

    public func start() async throws {
        try await reconfigure()
    }

    public func stop() async {
        cancelAllActivity()
        await operationLock.acquire()
        defer { operationLock.release() }
        stopSessions()
        statuses.removeAll()
    }

    /// Cancels in-flight scans and pending retries *before* waiting on `operationLock`, so a long scan
    /// cannot hold up stop/reconfigure. Cancelled scans exit at their next checkpoint.
    private func cancelAllActivity() {
        for session in sessions.values {
            session.consumer.cancel()
            session.initialScan?.cancel()
        }
        cancelRetries()
    }

    private func cancelRetries() {
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        retryAttempts.removeAll()
    }

    private func tearDown(_ session: RootWatchSession) {
        session.consumer.cancel()
        session.initialScan?.cancel()
        session.continuation.finish()
        session.eventStream.stop()
    }

    private func stopSessions() {
        for session in sessions.values { tearDown(session) }
        sessions.removeAll(keepingCapacity: false)
        cancelRetries()
    }

    public func reconfigure() async throws {
        cancelAllActivity()
        await operationLock.acquire()
        defer { operationLock.release() }
        let snapshot = try await store.loadSnapshot()
        let retainedPaths = Set(snapshot.managedRoots.map(\.path))
        let retainedIDs = Set(snapshot.managedRoots.map(\.id))
        let previousRoots = statuses.values.map(\.root)
        stopSessions()
        for root in previousRoots where !retainedIDs.contains(root.id) {
            statuses[root.id] = nil
            lastRecovery[root.id] = nil
            lastFailureAudit[root.id] = nil
            try await store.removeEventCursor(for: root.id)
            guard !retainedPaths.contains(root.path) else { continue }
            try await store.removeDeadlines(atOrBelow: root.path)
            try await store.removeObservedActivity(atOrBelow: root.path)
            try await store.removeProjectActivity(atOrBelow: root.path)
        }

        for root in snapshot.managedRoots {
            try await store.removeDeadlines(atOrBelow: root.path)
            do { try await startWatching(root) }
            catch { await handleRootFailure(root, error: error) }
        }
        onDeadlinesChanged()
    }

    func reconcileManagedRoots(at paths: [String]) async throws {
        let selectedPaths = Set(paths.map(RuleScope.normalized))
        guard !selectedPaths.isEmpty else { return }
        for session in sessions.values where selectedPaths.contains(session.root.path) {
            session.consumer.cancel()
            session.initialScan?.cancel()
        }
        await operationLock.acquire()
        defer { operationLock.release() }
        let snapshot = try await store.loadSnapshot()
        for root in snapshot.managedRoots where selectedPaths.contains(root.path) {
            retryTasks.removeValue(forKey: root.id)?.cancel()
            if let session = sessions.removeValue(forKey: root.id) { tearDown(session) }
            try await store.removeDeadlines(atOrBelow: root.path)
            do { try await startWatching(root) }
            catch { await handleRootFailure(root, error: error) }
        }
        onDeadlinesChanged()
    }

    /// After wake, every root resumes from its saved event cursor (FSEvents replays what was missed);
    /// a full scan only happens for roots without a cursor or without a live session.
    func resumeAfterWake() async throws {
        await operationLock.acquire()
        defer { operationLock.release() }
        let snapshot = try await store.loadSnapshot()
        for root in snapshot.managedRoots {
            retryTasks.removeValue(forKey: root.id)?.cancel()
            if let session = sessions.removeValue(forKey: root.id) { tearDown(session) }
            do { try await startWatching(root, replayFromCursorWithoutScan: true) }
            catch { await handleRootFailure(root, error: error) }
        }
        onDeadlinesChanged()
    }

    public func processChanges(_ event: ManagedRootEvent, for rootID: UUID) async throws {
        await operationLock.acquire()
        defer { operationLock.release() }
        guard let session = sessions[rootID], !session.recoveryLatch.isRequired else { return }
        let eventCount = min(event.paths.count, event.flags.count)
        let rootChangedFlag = UInt32(kFSEventStreamEventFlagRootChanged)
        if (0..<eventCount).contains(where: { UInt32(event.flags[$0]) & rootChangedFlag != 0 }) {
            session.recoveryLatch.request()
            statuses[rootID]?.state = .recovering
            Task { await self.recover(rootID: rootID) }
            return
        }
        let recoveryMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        if event.requiresRecovery || (0..<eventCount).contains(where: { UInt32(event.flags[$0]) & recoveryMask != 0 }) {
            let delay = recoveryDelay(for: rootID)
            if delay > 0 {
                // Repeated recoveries back off instead of rescanning the tree for every flood.
                session.recoveryLatch.request()
                statuses[rootID]?.state = .recovering
                Task { await self.recover(rootID: rootID, delay: delay) }
                return
            }
            diagnosticsRecorder.recordRecovery()
            let snapshot = try await store.loadSnapshot()
            try await scan(session.access.url, root: session.root, snapshot: snapshot, includeRoot: false)
            if let eventID = event.eventIDs.max() {
                do { try await store.saveEventCursor(for: rootID, eventID: eventID) }
                catch { throw SQLiteSafetyStoreError.statementFailed("save recovery cursor: \(error)") }
            }
            onDeadlinesChanged()
            return
        }

        struct CoalescedEvent {
            var flags: UInt32
            var eventID: UInt64?
        }
        var coalesced: [String: CoalescedEvent] = [:]
        for index in 0..<eventCount {
            let path = RuleScope.normalized(event.paths[index])
            var change = coalesced[path] ?? CoalescedEvent(flags: 0, eventID: nil)
            change.flags |= UInt32(event.flags[index])
            if index < event.eventIDs.count {
                let eventID = UInt64(event.eventIDs[index])
                change.eventID = max(change.eventID ?? eventID, eventID)
            }
            coalesced[path] = change
        }

        // Existence is read once per path, never inside the comparator.
        let existence = Dictionary(uniqueKeysWithValues: coalesced.keys.map { ($0, Self.pathExistsWithoutFollowingSymlinks($0)) })
        let paths = coalesced.keys.sorted {
            let lhsExists = existence[$0] ?? false
            let rhsExists = existence[$1] ?? false
            if lhsExists != rhsExists { return lhsExists }
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0 < $1
        }
        let snapshot = try await store.loadSnapshot()
        let now = clock.now()
        let tracksProjectActivity = snapshot.rules.contains { $0.expiryBasis == .projectActivity && $0.state != .paused }
        var scannedScopes: [String] = []
        var affectedProjects: Set<String> = []
        var failedPaths = 0
        var firstFailure: Error?

        for path in paths {
            try Task.checkCancellation()
            guard isWithinManagedRoot(path, rootPath: session.root.path),
                  !scannedScopes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            // Ignored subtrees (.git, node_modules, ...) are skipped at event time exactly as the scan skips them.
            if tracksProjectActivity,
               hasIgnoredProjectComponent(in: URL(fileURLWithPath: path).deletingLastPathComponent().path) { continue }
            do {
                let flags = coalesced[path]?.flags ?? 0
                let exists = Self.pathExistsWithoutFollowingSymlinks(path)
                if !exists {
                    if isMeaningfulProjectActivity(path),
                       let projectPath = try await store.recordProjectActivity(at: path, date: now) {
                        affectedProjects.insert(projectPath)
                    }
                    try await store.removeDeadlines(atOrBelow: path)
                    try await store.removeObservedActivity(atOrBelow: path)
                    try await store.removeProjectActivity(atOrBelow: path)
                    if isProjectMarker(path),
                       let parent = existingProjectScanParent(for: path, root: session.root) {
                        try await scan(parent, root: session.root, snapshot: snapshot, includeRoot: true)
                        scannedScopes.append(parent.path)
                    }
                    continue
                }

                // A symlink (or an entry that vanished meanwhile) is simply not indexable.
                guard let candidate = try await inspectIfIndexable(path) else { continue }
                let isMarker = isProjectMarker(path)
                let isDirectory = candidate.kind == .directory
                let isCreatedOrRenamed = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
                if isMarker {
                    let scanPath = URL(fileURLWithPath: path).deletingLastPathComponent()
                    try await scan(scanPath, root: session.root, snapshot: snapshot, includeRoot: true)
                    scannedScopes.append(scanPath.path)
                    if let refreshed = try await inspectIfIndexable(path) {
                        try await index(refreshed, snapshot: snapshot, activityAt: now)
                    }
                    continue
                }

                if isDirectory && isCreatedOrRenamed {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try await scan(directory, root: session.root, snapshot: snapshot, includeRoot: true)
                    scannedScopes.append(directory.path)
                    continue
                }

                if isMeaningfulProjectActivity(path),
                   (!isDirectory || isCreatedOrRenamed),
                   let projectPath = try await store.recordProjectActivity(at: path, date: now) {
                    affectedProjects.insert(projectPath)
                }
                try await index(candidate, snapshot: snapshot, activityAt: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One bad path must not abort the rest of the batch.
                failedPaths += 1
                if firstFailure == nil { firstFailure = error }
            }
        }

        for projectPath in affectedProjects.sorted()
            where !scannedScopes.contains(where: { projectPath == $0 || projectPath.hasPrefix($0 + "/") }) {
            do { try await refreshDeadlines(atOrBelow: projectPath, snapshot: snapshot) }
            catch is CancellationError { throw CancellationError() }
            catch {
                failedPaths += 1
                if firstFailure == nil { firstFailure = SQLiteSafetyStoreError.statementFailed("refresh project inactivity deadlines: \(error)") }
            }
        }
        if let firstFailure {
            await recordIndexFailure(root: session.root, error: firstFailure, summary: "\(failedPaths) changed path(s) could not be indexed")
        } else if !session.recoveryLatch.isRequired,
           let eventID = coalesced.values.compactMap(\.eventID).max() {
            // The cursor only advances past batches that were fully processed; otherwise a restart replays them.
            do { try await store.saveEventCursor(for: rootID, eventID: eventID) }
            catch { throw SQLiteSafetyStoreError.statementFailed("save event cursor: \(error)") }
        }
        onDeadlinesChanged()
    }

    private func existingProjectScanParent(for path: String, root: ManagedRoot) -> URL? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        guard isWithinManagedRoot(parent.path, rootPath: root.path),
              fileManager.fileExists(atPath: parent.path) else { return nil }
        return parent
    }

    private func refreshDeadlines(atOrBelow path: String, snapshot: PolicySnapshot) async throws {
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let page: PersistedDeadlinePage
            do { page = try await store.deadlinePage(atOrBelow: path, afterIdentityKey: cursor) }
            catch { throw SQLiteSafetyStoreError.statementFailed("query project deadline page: \(error)") }
            for deadline in page.deadlines {
                guard let candidate = try await inspectIfIndexable(deadline.identity.pathHint),
                      candidate.identity == deadline.identity else {
                    do { try await store.removeDeadline(for: deadline.identity, scheduledAt: deadline.scheduledAt) }
                    catch { throw SQLiteSafetyStoreError.statementFailed("remove stale project deadline: \(error)") }
                    continue
                }
                let refreshed: (deadline: PersistedDeadline?, newActivity: PersistedObservedActivity?)
                do { refreshed = try await scheduledDeadline(for: candidate, snapshot: snapshot) }
                catch { throw SQLiteSafetyStoreError.statementFailed("resolve project deadline: \(error)") }
                if let updated = refreshed.deadline {
                    do { try await store.saveDeadline(updated) }
                    catch { throw SQLiteSafetyStoreError.statementFailed("save refreshed project deadline: \(error)") }
                } else {
                    do { try await store.removeDeadline(for: deadline.identity, scheduledAt: deadline.scheduledAt) }
                    catch { throw SQLiteSafetyStoreError.statementFailed("remove ineligible project deadline: \(error)") }
                }
            }
            cursor = page.nextCursor
            if page.deadlines.isEmpty { break }
        } while cursor != nil
    }

    private func startWatching(_ root: ManagedRoot, replayFromCursorWithoutScan: Bool = false) async throws {
        statuses[root.id] = RootStatusEntry(root: root, state: .indexing, detail: nil)
        let resolvedURL: URL
        if let bookmarkResolver {
            resolvedURL = try bookmarkResolver(root)
        } else {
            var stale = false
            resolvedURL = try URL(
                resolvingBookmarkData: root.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                // A stale bookmark that still resolves to the managed path is repaired in place;
                // one that resolves elsewhere means the folder moved and needs the user to choose it again.
                guard RuleScope.normalized(resolvedURL.path) == root.path else {
                    throw ManagedRootIndexError.staleOrMovedBookmark(root.path)
                }
                try await refreshBookmark(for: root, at: resolvedURL)
            }
        }
        guard RuleScope.normalized(resolvedURL.path) == root.path else {
            throw ManagedRootIndexError.staleOrMovedBookmark(root.path)
        }
        let access = RootAccessToken(url: resolvedURL)
        let rootValues = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ManagedRootIndexError.unsafeRoot(root.path)
        }
        let (events, continuation) = AsyncStream<ManagedRootEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let diagnosticsRecorder = self.diagnosticsRecorder
        let recoveryLatch = RootRecoveryLatch()
        let savedCursor = try await store.eventCursor(for: root.id)
        let stream = try ManagedRootEventStream(
            rootPath: resolvedURL.path,
            since: savedCursor ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        ) { [weak self] event in
            switch continuation.yield(event) {
            case .enqueued(let remainingCapacity):
                diagnosticsRecorder.recordQueueDepth(512 - remainingCapacity)
            case .dropped:
                diagnosticsRecorder.recordQueueDepth(512)
                recoveryLatch.request()
                Task { await self?.recover(rootID: root.id) }
            case .terminated:
                break
            @unknown default:
                recoveryLatch.request()
                Task { await self?.recover(rootID: root.id) }
            }
        }
        let consumer = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                do { try await self?.processChanges(event, for: root.id) }
                catch is CancellationError { return }
                catch { await self?.handleEventFailure(root: root, error: error) }
            }
        }
        let scansNow = !(replayFromCursorWithoutScan && savedCursor != nil)
        let initialScan: Task<Void, Never>? = scansNow
            ? Task { [weak self] in
                guard let self else { return }
                await self.scanRoot(rootID: root.id)
            }
            : nil
        sessions[root.id] = RootWatchSession(root: root, access: access, eventStream: stream, continuation: continuation, consumer: consumer, recoveryLatch: recoveryLatch, initialScan: initialScan)
        if !scansNow {
            statuses[root.id] = RootStatusEntry(root: root, state: .watching, detail: nil)
            retryAttempts[root.id] = nil
        }
    }

    private func refreshBookmark(for root: ManagedRoot, at url: URL) async throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await store.updateManagedRootBookmark(
            rootID: root.id,
            bookmarkData: data,
            auditEvent: TrashAuditEvent(
                occurredAt: clock.now(),
                kind: .safetySkipped,
                detail: "Refreshed the stale access bookmark for \(root.path)."
            )
        )
    }

    private func scanRoot(rootID: UUID) async {
        await operationLock.acquire()
        defer { operationLock.release() }
        guard !Task.isCancelled, let session = sessions[rootID] else { return }
        do {
            let snapshot = try await store.loadSnapshot()
            try await scan(session.access.url, root: session.root, snapshot: snapshot, includeRoot: false)
            statuses[rootID] = RootStatusEntry(root: session.root, state: .watching, detail: nil)
            retryAttempts[rootID] = nil
            onDeadlinesChanged()
        } catch {
            await handleRootFailure(session.root, error: error)
        }
    }

    /// Debounce + exponential backoff for recovery rescans. The first recovery in a window is immediate.
    private func recoveryDelay(for rootID: UUID) -> TimeInterval {
        let now = clock.now()
        var streak = 0
        if let last = lastRecovery[rootID], now.timeIntervalSince(last.at) < Self.recoveryFloodWindow {
            streak = last.streak + 1
        }
        lastRecovery[rootID] = (now, streak)
        return streak == 0 ? 0 : min(60, pow(2, Double(streak)))
    }

    private func recover(rootID: UUID, delay explicitDelay: TimeInterval? = nil) async {
        guard recoveryRequests.insert(rootID).inserted else { return }
        defer { recoveryRequests.remove(rootID) }
        let delay = explicitDelay ?? recoveryDelay(for: rootID)
        if delay > 0 { try? await sleep(delay) }
        await operationLock.acquire()
        defer { operationLock.release() }
        guard let session = sessions[rootID] else { return }
        diagnosticsRecorder.recordRecovery()
        statuses[rootID]?.state = .recovering
        tearDown(session)
        sessions.removeValue(forKey: rootID)
        do {
            try await startWatching(session.root)
            onDeadlinesChanged()
        } catch {
            await handleRootFailure(session.root, error: error)
        }
    }

    /// A processing failure means events were consumed without being indexed; rescan via the debounced recovery path.
    private func handleEventFailure(root: ManagedRoot, error: Error) async {
        await recordIndexFailure(root: root, error: error)
        guard let session = sessions[root.id], !session.recoveryLatch.isRequired else { return }
        session.recoveryLatch.request()
        Task { await self.recover(rootID: root.id) }
    }

    private func handleRootFailure(_ root: ManagedRoot, error: Error) async {
        if error is CancellationError { return }
        let (state, detail) = Self.classify(error)
        statuses[root.id] = RootStatusEntry(root: root, state: state, detail: detail)
        await recordIndexFailure(root: root, error: error)
        scheduleRetry(for: root)
    }

    /// Failed starts, scans and recoveries are retried with capped exponential backoff until the root works
    /// or is removed; mount events also trigger an immediate reconcile.
    private func scheduleRetry(for root: ManagedRoot) {
        retryTasks[root.id]?.cancel()
        let attempt = retryAttempts[root.id, default: 0]
        retryAttempts[root.id] = attempt + 1
        let delay = min(300, 2 * pow(2, Double(min(attempt, 8))))
        let sleep = self.sleep
        retryTasks[root.id] = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.retryRoot(rootID: root.id, fallback: root)
        }
    }

    private func retryRoot(rootID: UUID, fallback: ManagedRoot) async {
        await operationLock.acquire()
        defer { operationLock.release() }
        guard !Task.isCancelled else { return }
        retryTasks[rootID] = nil
        let snapshot: PolicySnapshot
        do { snapshot = try await store.loadSnapshot() }
        catch {
            scheduleRetry(for: fallback)
            return
        }
        guard let root = snapshot.managedRoots.first(where: { $0.id == rootID }) else {
            statuses[rootID] = nil
            retryAttempts[rootID] = nil
            return
        }
        if let session = sessions.removeValue(forKey: rootID) { tearDown(session) }
        do {
            try await store.removeDeadlines(atOrBelow: root.path)
            try await startWatching(root)
        } catch {
            await handleRootFailure(root, error: error)
        }
    }

    private static func classify(_ error: Error) -> (AgentRootState, String?) {
        if let indexError = error as? ManagedRootIndexError {
            switch indexError {
            case .staleOrMovedBookmark:
                return (.bookmarkStale, "The folder moved or its access bookmark is out of date. Choose the folder again.")
            case .unsafeRoot:
                return (.error, "The managed folder is not a plain directory.")
            case .observedActivityMissing:
                return (.error, "\(error)")
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileReadNoPermission, .fileWriteNoPermission:
                return (.permissionDenied, "TinyPrune does not have permission to read this folder.")
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return (.offline, "The folder is not available (disconnected or removed).")
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                return (.permissionDenied, "TinyPrune does not have permission to read this folder.")
            case Int(ENOENT), Int(ENOTDIR), Int(ENXIO), Int(ENODEV):
                return (.offline, "The folder is not available (disconnected or removed).")
            default: break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return classify(underlying)
        }
        return (.error, "\(error)")
    }

    private func scan(_ url: URL, root: ManagedRoot, snapshot: PolicySnapshot, includeRoot: Bool) async throws {
        // Fail before touching any persisted state if the directory itself cannot be read.
        try Self.requireReadableDirectory(url.path)
        try Task.checkCancellation()
        let scanStarted = ProcessInfo.processInfo.systemUptime
        let cpuStarted = processCPUSeconds()
        var indexedEntries: UInt64 = 0
        try await store.removeDeadlines(atOrBelow: url.path)
        let observationTime = clock.now()
        let projectScanID = try await store.beginProjectActivityScan()
        do {
            indexedEntries = try await scanBody(
                url, root: root, snapshot: snapshot, includeRoot: includeRoot,
                scanID: projectScanID, observationTime: observationTime
            )
        } catch {
            try? await store.endProjectActivityScan(scanID: projectScanID)
            throw error
        }
        let usage = processUsage()
        diagnosticsRecorder.recordScan(
            entries: indexedEntries,
            duration: ProcessInfo.processInfo.systemUptime - scanStarted,
            cpu: max(0, processCPUSeconds() - cpuStarted),
            fullTree: !includeRoot && url.standardizedFileURL.path == root.path,
            residentBytes: usage.residentBytes
        )
        onDeadlinesChanged()
    }

    private static func requireReadableDirectory(_ path: String) throws {
        guard let handle = opendir(path) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        closedir(handle)
    }

    private func scanBody(
        _ url: URL,
        root: ManagedRoot,
        snapshot: PolicySnapshot,
        includeRoot: Bool,
        scanID projectScanID: String,
        observationTime: Date
    ) async throws -> UInt64 {
        var indexedEntries: UInt64 = 0
        let tracksProjectActivity = snapshot.rules.contains { $0.expiryBasis == .projectActivity && $0.state != .paused }
        let batches = ScanBatchAccumulator()

        if includeRoot, let candidate = try await inspectIfIndexable(url.path) {
            indexedEntries &+= 1
            try await collectProjectScanCandidate(
                candidate,
                root: root,
                snapshot: snapshot,
                scanID: projectScanID,
                observationTime: observationTime,
                tracksProjectActivity: tracksProjectActivity,
                batches: batches
            )
        }

        // Unreadable subdirectories and entries that vanish mid-scan are skipped and reported once;
        // they never abort indexing of the rest of the tree.
        var unreadableEntries = 0
        var firstUnreadable: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                unreadableEntries += 1
                if firstUnreadable == nil { firstUnreadable = error }
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        while let childURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if let values = try? childURL.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                continue
            }
            let inspected: RuleCandidate?
            do { inspected = try await inspectIfIndexable(childURL.path) }
            catch is CancellationError { throw CancellationError() }
            catch {
                unreadableEntries += 1
                if firstUnreadable == nil { firstUnreadable = error }
                continue
            }
            guard let candidate = inspected else { continue }
            indexedEntries &+= 1
            try await collectProjectScanCandidate(
                candidate,
                root: root,
                snapshot: snapshot,
                scanID: projectScanID,
                observationTime: observationTime,
                tracksProjectActivity: tracksProjectActivity,
                batches: batches
            )
            if tracksProjectActivity,
               candidate.kind == .directory,
               hasIgnoredProjectComponent(in: candidate.identity.pathHint) {
                enumerator.skipDescendants()
            }
        }

        try await persistProjectScanBatch(batches.take(), scanID: projectScanID)
        try await store.finishProjectActivityScan(scanID: projectScanID, atOrBelow: url.path)
        if tracksProjectActivity {
            try await scanDeadlines(url, snapshot: snapshot, includeRoot: includeRoot, initialObservationAt: observationTime)
        }
        if let firstUnreadable {
            await recordIndexFailure(
                root: root,
                error: firstUnreadable,
                summary: "\(unreadableEntries) unreadable entr\(unreadableEntries == 1 ? "y was" : "ies were") skipped while indexing"
            )
        }
        return indexedEntries
    }

    private func collectProjectScanCandidate(
        _ candidate: RuleCandidate,
        root: ManagedRoot,
        snapshot: PolicySnapshot,
        scanID: String,
        observationTime: Date,
        tracksProjectActivity: Bool,
        batches: ScanBatchAccumulator
    ) async throws {
        let project = try await projectRoot(for: candidate, managedRoot: root, at: observationTime)
        let sourceObservation: ProjectActivityObservation?
        if tracksProjectActivity,
           candidate.kind == .file,
           isMeaningfulProjectActivity(candidate.identity.pathHint),
           let modifiedAt = candidate.timestamps.modified {
            sourceObservation = ProjectActivityObservation(path: candidate.identity.pathHint, modifiedAt: modifiedAt)
        } else {
            sourceObservation = nil
        }
        let prepared = tracksProjectActivity
            ? nil
            : try await scheduledDeadline(for: candidate, snapshot: snapshot, initialObservationAt: observationTime)
        if let batch = batches.append(
            project: project,
            sourceObservation: sourceObservation,
            deadline: prepared?.deadline,
            observedActivity: prepared?.newActivity
        ) {
            try await persistProjectScanBatch(batch, scanID: scanID)
        }
    }

    private func persistProjectScanBatch(_ batch: ScanBatch, scanID: String) async throws {
        if !batch.projects.isEmpty {
            try await store.recordProjectActivities(batch.projects, scanID: scanID)
            diagnosticsRecorder.recordPersistenceBatch(batch.projects.count)
        }
        if !batch.sourceObservations.isEmpty {
            try await store.recordProjectObservations(batch.sourceObservations, scanID: scanID)
            diagnosticsRecorder.recordPersistenceBatch(batch.sourceObservations.count)
        }
        try await persistBatch(deadlines: batch.deadlines, activities: batch.observedActivity)
    }

    private func scanDeadlines(
        _ url: URL,
        snapshot: PolicySnapshot,
        includeRoot: Bool,
        initialObservationAt: Date
    ) async throws {
        let batches = ScanBatchAccumulator()
        if includeRoot, let candidate = try await inspectIfIndexable(url.path) {
            try await collectDeadline(candidate, snapshot: snapshot, initialObservationAt: initialObservationAt, batches: batches)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let childURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if let values = try? childURL.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                continue
            }
            let inspected: RuleCandidate?
            do { inspected = try await inspectIfIndexable(childURL.path) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            guard let candidate = inspected else { continue }
            try await collectDeadline(candidate, snapshot: snapshot, initialObservationAt: initialObservationAt, batches: batches)
        }
        let batch = batches.take()
        try await persistBatch(deadlines: batch.deadlines, activities: batch.observedActivity)
    }

    private func collectDeadline(
        _ candidate: RuleCandidate,
        snapshot: PolicySnapshot,
        initialObservationAt: Date,
        batches: ScanBatchAccumulator
    ) async throws {
        let prepared = try await scheduledDeadline(for: candidate, snapshot: snapshot, initialObservationAt: initialObservationAt)
        if let batch = batches.append(deadline: prepared.deadline, observedActivity: prepared.newActivity) {
            try await persistBatch(deadlines: batch.deadlines, activities: batch.observedActivity)
        }
    }


    private func projectRoot(
        for candidate: RuleCandidate,
        managedRoot: ManagedRoot,
        at fallbackActivity: Date
    ) async throws -> PersistedProjectActivity? {
        guard Self.projectMarkers.contains(candidate.name),
              !hasIgnoredProjectComponent(in: URL(fileURLWithPath: candidate.identity.pathHint).deletingLastPathComponent().path) else {
            return nil
        }
        let path = URL(fileURLWithPath: candidate.identity.pathHint).deletingLastPathComponent().standardizedFileURL.path
        guard isWithinManagedRoot(path, rootPath: managedRoot.path),
              let rootCandidate = try await inspectIfIndexable(path),
              rootCandidate.kind == .directory else { return nil }
        return PersistedProjectActivity(
            identity: rootCandidate.identity,
            lastActivityAt: candidate.timestamps.modified ?? fallbackActivity
        )
    }

    private func isMeaningfulProjectActivity(_ path: String) -> Bool {
        let normalizedPath = RuleScope.normalized(path)
        guard !hasIgnoredProjectComponent(in: normalizedPath) else { return false }
        return !URL(fileURLWithPath: normalizedPath).lastPathComponent.lowercased().hasSuffix(".log")
    }

    private func isProjectMarker(_ path: String) -> Bool {
        let marker = URL(fileURLWithPath: path).lastPathComponent
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return Self.projectMarkers.contains(marker) && !hasIgnoredProjectComponent(in: parent)
    }

    private func hasIgnoredProjectComponent(in path: String) -> Bool {
        let components = RuleScope.normalized(path).split(separator: "/").map(String.init)
        let ignored: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".cache", "dist", "build", "target"]
        guard !components.contains(where: ignored.contains) else { return true }
        return zip(components, components.dropFirst()).contains { $0 == ".next" && $1 == "cache" }
    }

    private static let projectMarkers: Set<String> = [
        ".git", "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml",
        "go.mod", "Gemfile", "pom.xml", "build.gradle", "composer.json"
    ]

    private func persistBatch(deadlines: [PersistedDeadline], activities: [PersistedObservedActivity]) async throws {
        if !activities.isEmpty {
            try await store.recordInitialObservations(activities)
            diagnosticsRecorder.recordPersistenceBatch(activities.count)
        }
        if !deadlines.isEmpty {
            try await store.saveDeadlines(deadlines)
            diagnosticsRecorder.recordPersistenceBatch(deadlines.count)
        }

    }
    private func index(_ candidate: RuleCandidate, snapshot: PolicySnapshot, activityAt date: Date) async throws {
        let prepared = try await scheduledDeadline(for: candidate, snapshot: snapshot, activityAt: date)
        if let deadline = prepared.deadline {
            try await store.saveDeadline(deadline)
        } else {
            try await store.removeDeadline(for: candidate.identity)
        }
    }

    private func scheduledDeadline(
        for candidate: RuleCandidate,
        snapshot: PolicySnapshot,
        initialObservationAt: Date? = nil,
        activityAt: Date? = nil
    ) async throws -> (deadline: PersistedDeadline?, newActivity: PersistedObservedActivity?) {
        var suppliedActivity: PersistedObservedActivity?
        var newActivity: PersistedObservedActivity?
        if IndexedCandidateEvaluation.usesObservedActivity(candidate, rules: snapshot.rules) {
            let activity: PersistedObservedActivity
            if let activityAt {
                try await store.recordObservedActivity(identity: candidate.identity, at: activityAt)
                guard let recordedActivity = try await store.observedActivity(for: candidate.identity) else {
                    throw ManagedRootIndexError.observedActivityMissing(candidate.identity.pathHint)
                }
                activity = recordedActivity
            } else if let existing = try await store.observedActivity(for: candidate.identity) {
                if let modifiedAt = candidate.timestamps.modified, modifiedAt > existing.lastObservedAt {
                    try await store.reconcileObservedActivity(identity: candidate.identity, through: modifiedAt)
                    activity = PersistedObservedActivity(
                        identity: candidate.identity,
                        firstObservedAt: existing.firstObservedAt,
                        lastObservedAt: modifiedAt
                    )
                } else {
                    activity = existing
                }
            } else {
                let now = initialObservationAt ?? clock.now()
                activity = PersistedObservedActivity(identity: candidate.identity, firstObservedAt: now, lastObservedAt: now)
                newActivity = activity
            }
            suppliedActivity = activity
        }
        let evaluatedCandidate = try await IndexedCandidateEvaluation.hydrate(
            candidate, rules: snapshot.rules, store: store,
            now: initialObservationAt ?? clock.now(), suppliedActivity: suppliedActivity
        )
        let explanation: CandidateExplanation
        switch IndexedCandidateEvaluation.resolve(evaluatedCandidate, rules: snapshot.rules, snapshot: snapshot) {
        case .scheduled(let scheduled): explanation = scheduled
        case .customExpiry(let custom): explanation = CandidateExplanation(customExpiry: custom)
        default: return (nil, newActivity)
        }
        return (PersistedDeadline(identity: candidate.identity, scheduledAt: explanation.scheduledAt, explanation: explanation), newActivity)
    }

    /// Read-only lease on an available managed root so a dry run can traverse inside its security scope.
    func leaseManagedRoot(containing path: String) -> (rootPath: String, access: RootAccessToken)? {
        let normalizedPath = RuleScope.normalized(path)
        for session in sessions.values {
            let rootPath = RuleScope.normalized(session.access.url.path)
            if isWithinManagedRoot(normalizedPath, rootPath: rootPath) { return (rootPath, session.access) }
        }
        return nil
    }

    private func isWithinManagedRoot(_ path: String, rootPath: String) -> Bool {
        let candidatePath = RuleScope.normalized(path)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// Audit entries are rate-limited per root so a persistent failure cannot flood the log.
    private func recordIndexFailure(root: ManagedRoot, error: Error, summary: String? = nil) async {
        let now = clock.now()
        if let last = lastFailureAudit[root.id], now.timeIntervalSince(last) < Self.failureAuditInterval { return }
        lastFailureAudit[root.id] = now
        let reason = summary.map { "\($0): \(error)" } ?? "\(error)"
        try? await store.append(TrashAuditEvent(
            occurredAt: now,
            kind: .safetySkipped,
            detail: "Indexing root \(root.path) stopped safely: \(reason)"
        ))
    }

    private func processUsage() -> (residentBytes: UInt64, cpuSeconds: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return (UInt64(max(0, usage.ru_maxrss)), user + system)
    }

    private func processCPUSeconds() -> Double {
        processUsage().cpuSeconds
    }
}

public enum ManagedRootIndexError: Error, Equatable, Sendable {
    case staleOrMovedBookmark(String)
    case unsafeRoot(String)
    case observedActivityMissing(String)
}
