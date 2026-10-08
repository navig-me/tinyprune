import TinyPruneDomain
import Foundation
import TinyPruneEngine
import TinyPrunePersistence
import TinyPruneIPC

public actor DeadlineScheduler {
    private let store: SQLiteSafetyStore
    private let coordinator: TrashCoordinator
    private let clock: any SafetyClock
    private let onWaitingForDeadline: @Sendable () -> Void
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var changeVersion: UInt64 = 0
    private var sleeperGeneration: UInt64 = 0
    private var updateObserver: UpdateInstallationObservation?
    private var backoff: [BackoffKey: BackoffEntry] = [:]
    private var runInProgress = false
    private var runWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: SQLiteSafetyStore, coordinator: TrashCoordinator, clock: any SafetyClock = SystemSafetyClock()) {
        self.store = store
        self.coordinator = coordinator
        self.clock = clock
        self.onWaitingForDeadline = {}
    }

    init(
        store: SQLiteSafetyStore,
        coordinator: TrashCoordinator,
        clock: any SafetyClock,
        onWaitingForDeadline: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.coordinator = coordinator
        self.clock = clock
        self.onWaitingForDeadline = onWaitingForDeadline
    }

    public func start() throws {
        guard worker == nil else { return }
        updateObserver = try coordinator.observeUpdateGateChanges { [weak self] in
            Task { await self?.signalChange() }
        }
        worker = Task { await runLoop() }
    }

    public func stop() async {
        let activeWorker = worker
        activeWorker?.cancel()
        worker = nil
        updateObserver = nil
        signalChange()
        await activeWorker?.value
    }

    public func signalChange() {
        changeVersion &+= 1
        // Any policy/deadline/update-gate change may make a backed-off item runnable (or obsolete) right now.
        backoff.removeAll()
        sleeperGeneration &+= 1
        sleeper?.cancel()
        sleeper = nil
        let pending = waiter
        waiter = nil
        pending?.resume()
    }

    /// Executes every due deadline once. A deadline that is deferred, or whose execution fails, stays persisted and
    /// is retried after a capped exponential backoff on the injected clock; it never blocks other due deadlines.
    public func runDueNow() async throws {
        // Executions are serialized: awaits inside a pass would otherwise let two passes execute the same deadline.
        await acquireRun()
        defer { releaseRun() }
        try await drainDueDeadlines()
    }

    private func acquireRun() async {
        if !runInProgress {
            runInProgress = true
            return
        }
        await withCheckedContinuation { runWaiters.append($0) }
    }

    private func releaseRun() {
        if runWaiters.isEmpty {
            runInProgress = false
        } else {
            runWaiters.removeFirst().resume()
        }
    }

    private func drainDueDeadlines() async throws {
        if try await store.loadSnapshot().globallyPaused { return }
        while !Task.isCancelled {
            let now = clock.now()
            pruneBackoff(now: now)
            guard let deadline = try await nextRunnableDeadline(now: now) else { return }
            let request = TrashRequest(
                candidateIdentity: deadline.identity,
                source: deadline.source,
                scheduledAt: deadline.scheduledAt
            )
            let outcome: TrashExecutionOutcome
            do {
                outcome = try await coordinator.execute(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch TrashExecutionError.movedButAuditFailed {
                // The item is already in the Trash; the deadline is obsolete even though the audit write failed.
                try await store.removeDeadline(for: deadline.identity, scheduledAt: deadline.scheduledAt)
                continue
            } catch {
                recordFailure(for: deadline, now: clock.now(), base: Self.errorBackoffBase)
                continue
            }
            switch outcome {
            case .movedToTrash, .skipped:
                try await store.removeDeadline(for: deadline.identity, scheduledAt: deadline.scheduledAt)
                backoff[BackoffKey(deadline)] = nil
            case .previewed, .deferred:
                recordFailure(for: deadline, now: clock.now(), base: Self.deferralBackoffBase)
            case .notDue(let dueAt):
                backoff[BackoffKey(deadline)] = BackoffEntry(until: max(dueAt, clock.now().addingTimeInterval(1)), failures: 0)
            }
        }
    }

    private struct BackoffKey: Hashable {
        let identity: FilesystemIdentity
        let scheduledAt: Date
        init(_ deadline: PersistedDeadline) {
            identity = deadline.identity
            scheduledAt = deadline.scheduledAt
        }
    }

    private struct BackoffEntry {
        var until: Date
        var failures: Int
    }

    private static let errorBackoffBase: TimeInterval = 30
    private static let deferralBackoffBase: TimeInterval = 300
    private static let maximumBackoff: TimeInterval = 3_600

    private func recordFailure(for deadline: PersistedDeadline, now: Date, base: TimeInterval) {
        let key = BackoffKey(deadline)
        let failures = (backoff[key]?.failures ?? 0) + 1
        let delay = min(Self.maximumBackoff, base * pow(2, Double(min(failures - 1, 10))))
        backoff[key] = BackoffEntry(until: now.addingTimeInterval(delay), failures: failures)
    }

    private func pruneBackoff(now: Date) {
        // Entries are keyed by the deadline they were recorded for; ones long expired belong to rows that are gone.
        backoff = backoff.filter { $0.value.until > now.addingTimeInterval(-Self.maximumBackoff) }
    }

    /// Earliest due deadline that is not backed off. Backed-off rows sort among the others, so the page is sized to
    /// guarantee at least one non-backed-off row whenever one exists.
    private func nextRunnableDeadline(now: Date) async throws -> PersistedDeadline? {
        let page = try await store.upcomingDeadlines(limit: backoff.count + 16)
        return page.first { $0.scheduledAt <= now && !isBackedOff($0, now: now) }
    }

    private func isBackedOff(_ deadline: PersistedDeadline, now: Date) -> Bool {
        guard let entry = backoff[BackoffKey(deadline)] else { return false }
        return entry.until > now
    }

    /// When the loop should next act: the earliest of any row's due time or its backoff expiry.
    private func nextWakeTime(now: Date) async throws -> Date? {
        let page = try await store.upcomingDeadlines(limit: backoff.count + 16)
        return page.map { deadline -> Date in
            if let entry = backoff[BackoffKey(deadline)] { return max(deadline.scheduledAt, entry.until) }
            return deadline.scheduledAt
        }.min()
    }

    private func runLoop() async {
        // Attempts left in flight by a previous run are closed out in the audit log before anything new executes.
        _ = try? await store.reconcileInterruptedTrashAttempts()
        while !Task.isCancelled {
            let observedVersion = changeVersion
            do {
                let snapshot = try await store.loadSnapshot()
                if snapshot.globallyPaused {
                    if let until = snapshot.pausedUntil {
                        await waitForChangeOrDeadline(until.timeIntervalSince(clock.now()), version: observedVersion)
                    } else {
                        await waitForChange(version: observedVersion)
                    }
                    continue
                }
                if let wake = try await nextWakeTime(now: clock.now()) {
                    let delay = wake.timeIntervalSince(clock.now())
                    if delay <= 0 {
                        try await runDueNow()
                        continue
                    }
                    await waitForChangeOrDeadline(delay, version: observedVersion)
                } else {
                    await waitForChange(version: observedVersion)
                }
            } catch {
                await waitForChange(version: observedVersion)
            }
        }
    }

    private func waitForChangeOrDeadline(_ delay: TimeInterval, version: UInt64) async {
        guard changeVersion == version else { return }
        await waitForChange(version: version, deadline: delay)
    }

    private func waitForChange(version: UInt64, deadline: TimeInterval? = nil) async {
        guard changeVersion == version, !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            guard changeVersion == version, !Task.isCancelled else {
                continuation.resume()
                return
            }
            waiter = continuation
            if let deadline {
                let nanoseconds = UInt64(min(max(deadline, 0), 86_400 * 365) * 1_000_000_000)
                sleeperGeneration &+= 1
                let generation = sleeperGeneration
                sleeper = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    await self?.deadlineReached(generation)
                }
                onWaitingForDeadline()
            }
        }
    }
    private func deadlineReached(_ generation: UInt64) {
        guard generation == sleeperGeneration else { return }
        signalChange()
    }
}
