import Foundation
import TinyPruneEngine
import TinyPrunePersistence

public actor ManagedRootAgentRuntime {
    private let indexer: ManagedRootIndexer
    private let scheduler: DeadlineScheduler

    public init(store: SQLiteSafetyStore, clock: any SafetyClock = SystemSafetyClock()) {
        let fileAccess = LocalTrashFileAccess()
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: store, clock: clock)
        let scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: clock)
        self.scheduler = scheduler
        self.indexer = ManagedRootIndexer(store: store, fileAccess: fileAccess) {
            Task { await scheduler.signalChange() }
        }
    }

    public func start() async throws {
        try await indexer.start()
        await scheduler.start()
    }

    public func policyDidChange() async throws {
        try await indexer.reconfigure()
        await scheduler.signalChange()
    }

    public func stop() async {
        await indexer.stop()
        await scheduler.stop()
    }
}
