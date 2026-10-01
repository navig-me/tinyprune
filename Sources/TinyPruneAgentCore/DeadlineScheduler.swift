import Foundation
import TinyPruneEngine
import TinyPrunePersistence

public actor DeadlineScheduler {
    private let store: SQLiteSafetyStore
    private let coordinator: TrashCoordinator
    private let clock: any SafetyClock
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var changeVersion: UInt64 = 0
    private var sleeperGeneration: UInt64 = 0

    public init(store: SQLiteSafetyStore, coordinator: TrashCoordinator, clock: any SafetyClock = SystemSafetyClock()) {
        self.store = store
        self.coordinator = coordinator
        self.clock = clock
    }

    public func start() {
        guard worker == nil else { return }
        worker = Task { await runLoop() }
    }

    public func stop() {
        worker?.cancel()
        worker = nil
        signalChange()
    }

    public func signalChange() {
        changeVersion &+= 1
        sleeperGeneration &+= 1
        sleeper?.cancel()
        sleeper = nil
        let pending = waiter
        waiter = nil
        pending?.resume()
    }

    public func runDueNow() async throws {
        while let deadline = try await store.nextDeadline(), deadline.scheduledAt <= clock.now() {
            let request = TrashRequest(
                candidateIdentity: deadline.identity,
                source: .rule(deadline.explanation.matchedRuleID),
                scheduledAt: deadline.scheduledAt
            )
            let outcome = try await coordinator.execute(request)
            if case .notDue = outcome { return }
            try await store.removeDeadline(for: deadline.identity)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let observedVersion = changeVersion
            do {
                if let deadline = try await store.nextDeadline() {
                    let delay = deadline.scheduledAt.timeIntervalSince(clock.now())
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
            }
        }
    }
    private func deadlineReached(_ generation: UInt64) {
        guard generation == sleeperGeneration else { return }
        signalChange()
    }
}
