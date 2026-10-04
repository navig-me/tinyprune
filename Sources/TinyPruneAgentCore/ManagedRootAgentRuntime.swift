import Foundation
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

public actor ManagedRootAgentRuntime {
    private let indexer: ManagedRootIndexer
    private let scheduler: DeadlineScheduler
    private let store: SQLiteSafetyStore
    private let clock: any SafetyClock
    private let rulePreview: RulePreviewConfiguration
    private let operationGate = ManagedRootRuntimeOperationGate()
    private var lifecycle: ManagedRootWorkspaceLifecycle?
    private var lifecycleGeneration: UUID?

    public init(
        store: SQLiteSafetyStore,
        clock: any SafetyClock = SystemSafetyClock(),
        rulePreview: RulePreviewConfiguration = RulePreviewConfiguration()
    ) {
        self.store = store
        self.clock = clock
        self.rulePreview = rulePreview
        let fileAccess = LocalTrashFileAccess()
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: store, clock: clock)
        let scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: clock)
        self.scheduler = scheduler
        self.indexer = ManagedRootIndexer(store: store, fileAccess: fileAccess, clock: clock) {
            Task { await scheduler.signalChange() }
        }
    }

    init(
        store: SQLiteSafetyStore,
        resolver: @escaping @Sendable (ManagedRoot) throws -> URL,
        clock: any SafetyClock = SystemSafetyClock(),
        rulePreview: RulePreviewConfiguration = RulePreviewConfiguration()
    ) {
        self.store = store
        self.clock = clock
        self.rulePreview = rulePreview
        let fileAccess = LocalTrashFileAccess()
        let coordinator = TrashCoordinator(policyStore: store, fileAccess: fileAccess, audit: store, clock: clock)
        let scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: clock)
        self.scheduler = scheduler
        self.indexer = ManagedRootIndexer(store: store, resolver: resolver, clock: clock) {
            Task { await scheduler.signalChange() }
        }
    }

    public func start() async throws {
        await operationGate.acquire()
        guard lifecycleGeneration == nil else {
            await operationGate.release()
            return
        }
        do {
            try await store.performMaintenance()
        } catch {
            try? await store.append(TrashAuditEvent(
                occurredAt: clock.now(),
                kind: .safetySkipped,
                detail: "SQLite maintenance stopped safely: \(error)"
            ))
        }
        let generation = UUID()
        lifecycleGeneration = generation
        let lifecycle = await ManagedRootWorkspaceLifecycle { [weak self] event in
            Task { await self?.workspaceDidChange(event, generation: generation) }
        }
        self.lifecycle = lifecycle
        await lifecycle.start()
        do {
            try await indexer.start()
            try await scheduler.start()
            await operationGate.release()
        } catch {
            lifecycleGeneration = nil
            await lifecycle.stop()
            self.lifecycle = nil
            await indexer.stop()
            await operationGate.release()
            throw error
        }
    }

    public func policyDidChange() async throws {
        await operationGate.acquire()
        do {
            try await indexer.reconfigure()
            await scheduler.signalChange()
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    public func stop() async {
        await operationGate.acquire()
        lifecycleGeneration = nil
        await lifecycle?.stop()
        lifecycle = nil
        await indexer.stop()
        await scheduler.stop()
        do { try await store.performMaintenance() }
        catch {
            try? await store.append(TrashAuditEvent(
                occurredAt: clock.now(),
                kind: .safetySkipped,
                detail: "SQLite maintenance stopped safely: \(error)"
            ))
        }
        await operationGate.release()
    }

    public func diagnosticsSnapshot() async -> ManagedRootDiagnosticsSnapshot {
        await indexer.diagnosticsSnapshot()
    }

    public func inspectManagedPath(_ path: String) async throws -> RuleCandidate? {
        guard let candidate = try await indexer.inspectManagedPath(path) else { return nil }
        let snapshot = try await store.loadSnapshot()
        return try await IndexedCandidateEvaluation.hydrate(candidate, rules: snapshot.rules, store: store, now: clock.now())
    }

    public func reconcileItemOverride(at path: String) async throws {
        try await indexer.reconcileManagedItem(path)
        await scheduler.signalChange()
    }

    /// Measures an item inside an available managed root on a detached task so scheduling is never blocked.
    /// Returns nil when the path is outside every available managed root or no longer exists.
    public func measureItem(path: String) async throws -> ItemSizeMeasurement? {
        guard try await indexer.inspectManagedPath(path) != nil else { return nil }
        return await Task.detached(priority: .utility) { ItemSizeMeasurer.measure(path: path) }.value
    }

    /// Explicit read-only rule dry run (ADR 0003). The traversal runs on a detached task, never on the scheduler,
    /// indexer or this actor, and requires the rule's folder to be inside an available managed root.
    public func previewRule(_ rule: LifetimeRule) async throws -> AgentRulePreview {
        guard let lease = await indexer.leaseManagedRoot(containing: rule.scope.path) else {
            throw RulePreviewError.invalidRequest("The rule's folder must be inside an available managed folder.")
        }
        let snapshot = try await store.loadSnapshot()
        return try await RulePreviewer(
            store: store,
            fileAccess: LocalTrashFileAccess(),
            clock: clock,
            configuration: rulePreview
        ).run(rule: rule, snapshot: snapshot, access: lease.access)
    }

    public func rebuildIndex() async throws {
        try await policyDidChange()
    }

    public func schedulingPolicyDidChange() async {
        await scheduler.signalChange()
    }

    private func workspaceDidChange(_ event: ManagedRootWorkspaceEvent, generation: UUID) async {
        await operationGate.acquire()
        guard lifecycleGeneration == generation else {
            await operationGate.release()
            return
        }
        do {
            if event == .woke {
                try await indexer.reconfigure()
            } else {
                let snapshot = try await store.loadSnapshot()
                let affectedRoots = event.affectedRootPaths(rootPaths: snapshot.managedRoots.map(\.path))
                guard !affectedRoots.isEmpty else {
                    await operationGate.release()
                    return
                }
                try await indexer.reconcileManagedRoots(at: affectedRoots)
            }
            await scheduler.signalChange()
        } catch {
            // Per-root failures are audited by the indexer; this covers failures
            // before it can inspect a root, such as loading persisted policy.
            try? await store.append(TrashAuditEvent(
                occurredAt: clock.now(),
                kind: .safetySkipped,
                detail: "Workspace recovery stopped safely: \(error)"
            ))
        }
        await operationGate.release()
    }
}
