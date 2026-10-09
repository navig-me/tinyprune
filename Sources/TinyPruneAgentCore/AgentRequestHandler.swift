import Foundation
import TinyPruneEngine
import TinyPruneIPC
import TinyPruneDomain
import TinyPrunePersistence

public actor AgentRequestHandler {
    private let store: SQLiteSafetyStore
    private let serviceVersion: String
    private let runtime: ManagedRootAgentRuntime?
    private let clock: any SafetyClock
    private let calendar: Calendar

    /// Mutating operations run one at a time: their read-modify-write sequences span awaits and must not interleave.
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: SQLiteSafetyStore, runtime: ManagedRootAgentRuntime? = nil, serviceVersion: String = "0.1.10", clock: any SafetyClock = SystemSafetyClock(), calendar: Calendar = .current) {
        self.store = store
        self.runtime = runtime
        self.serviceVersion = serviceVersion
        self.clock = clock
        self.calendar = calendar
    }

    private func acquireMutation() async {
        if !mutationInFlight {
            mutationInFlight = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationInFlight = false
        } else {
            // Ownership passes directly to the next waiter; the flag stays set.
            mutationWaiters.removeFirst().resume()
        }
    }

    private static func isMutating(_ operation: AgentOperation) -> Bool {
        switch operation {
        case .replacePolicy, .setItemOverride, .clearItemOverride, .setGlobalPause, .pauseUntil,
             .updateSettings, .deleteRule, .rebuildIndex, .saveRule, .setItemOverrides:
            true
        case .health, .loadPolicy, .loadOverview, .loadActivity, .explainItem, .loadSettings,
             .itemSize, .previewRule, .loadRoots, .cancelPreview:
            false
        }
    }

    public func handle(_ data: Data) async -> Data {
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: data) else {
            return encode(AgentResponse(payload: .failure(.invalidRequest("Request payload is malformed."))))
        }
        guard request.protocolVersion == TinyPruneAgentXPC.protocolVersion else {
            return encode(AgentResponse(payload: .failure(.unsupportedProtocol(
                expected: TinyPruneAgentXPC.protocolVersion,
                received: request.protocolVersion
            ))))
        }

        let mutating = Self.isMutating(request.operation)
        if mutating { await acquireMutation() }
        defer { if mutating { releaseMutation() } }
        return await perform(request.operation)
    }

    private func perform(_ operation: AgentOperation) async -> Data {
        do {
            switch operation {
            case .health:
                return encode(AgentResponse(payload: .health(AgentHealth(serviceVersion: serviceVersion))))
            case .loadPolicy:
                let snapshot = try await store.loadSnapshot()
                return encode(AgentResponse(payload: .policy(agentPolicy(from: snapshot))))
            case .loadOverview:
                let snapshot = try await store.loadSnapshot()
                let upcoming = try await store.upcomingDeadlines(limit: 200).map { AgentUpcomingItem(explanation: $0.explanation) }
                let stats = try await store.deadlineCountsByRule(now: clock.now()).map { AgentRuleStats(ruleID: $0.key, matches: $0.value.matches, due: $0.value.due) }
                let statuses = await runtime?.rootStatuses() ?? []
                let reclaimed = try await reclaimedSummary(now: clock.now())
                return encode(AgentResponse(payload: .overview(AgentOverviewSnapshot(
                    policy: agentPolicy(from: snapshot),
                    upcoming: upcoming,
                    ruleStats: stats,
                    indexedItems: try await store.indexedDeadlineCount(),
                    databaseBytes: await store.databaseSizeBytes(),
                    rootStatuses: statuses,
                    reclaimed: reclaimed
                ))))
            case .loadRoots:
                let snapshot = try await store.loadSnapshot()
                let roots = snapshot.managedRoots.map {
                    AgentRootSummary(id: $0.id, path: $0.path, name: URL(fileURLWithPath: $0.path).lastPathComponent)
                }
                return encode(AgentResponse(payload: .roots(roots)))
            case .cancelPreview:
                await runtime?.cancelPreviews()
                return encode(AgentResponse(payload: .acknowledged))
            case .loadActivity(let requestedLimit):
                let limit = min(max(requestedLimit, 1), 500)
                let events = try await store.auditEvents(limit: limit)
                let activity = events.compactMap { event -> AgentActivityItem? in
                    guard let kind = AgentActivityKind(rawValue: event.kind.rawValue) else { return nil }
                    return AgentActivityItem(
                        id: event.id,
                        occurredAt: event.occurredAt,
                        kind: kind,
                        identity: event.identity,
                        ruleID: event.ruleID,
                        detail: event.detail,
                        bytes: event.bytes,
                        itemCount: event.itemCount
                    )
                }
                return encode(AgentResponse(payload: .activity(activity)))
            case .explainItem(let path):
                let normalizedPath = RuleScope.normalized(path)
                guard path == normalizedPath, path.hasPrefix("/") else {
                    return invalid("Item paths must be normalized absolute paths.")
                }
                let snapshot = try await store.loadSnapshot()
                guard let runtime, let candidate = try await runtime.inspectManagedPath(normalizedPath) else {
                    return await unavailableItem(path: normalizedPath, roots: snapshot.managedRoots)
                }
                let resolution = RuleResolver.resolve(
                    candidate: candidate,
                    rules: snapshot.rules,
                    overrides: snapshot.overrides,
                    globallyPaused: snapshot.globallyPaused,
                    settings: snapshot.settings
                )
                let relevant = snapshot.overrides.filter { normalizedPath == $0.path || normalizedPath.hasPrefix($0.path + "/") }
                return encode(AgentResponse(payload: .itemExplanation(AgentItemExplanation(
                    path: normalizedPath,
                    identity: candidate.identity,
                    resolution: resolution,
                    overrides: relevant,
                    globallyPaused: snapshot.globallyPaused
                ))))
            case .replacePolicy(let policy):
                let previous = try await store.loadSnapshot()
                guard policy.revision == previous.revision else {
                    return encode(AgentResponse(payload: .failure(.policyConflict)))
                }
                if let error = validationError(for: policy, existingOverridePaths: Set(previous.overrides.map(\.path))) {
                    return encode(AgentResponse(payload: .failure(.invalidRequest(error))))
                }
                try await store.replaceSnapshot(
                    PolicySnapshot(
                        rules: policy.rules,
                        overrides: policy.overrides,
                        managedRoots: policy.managedRoots,
                        globallyPaused: policy.globallyPaused,
                        pausedUntil: policy.pausedUntil
                    ),
                    auditEvents: mutationEvents(from: previous, to: policy),
                    expectedRevision: policy.revision
                )
                if let runtime {
                    do { try await runtime.policyDidChange() }
                    catch { return encode(AgentResponse(payload: .failure(.storageUnavailable("Policy was saved, but root indexing failed: \(error)")))) }
                }
                return encode(AgentResponse(payload: .acknowledged))
            case .saveRule(let rule, let roots, let keepPaths, let unkeepPaths, let revision):
                return try await saveRule(rule: rule, roots: roots, keepPaths: keepPaths, unkeepPaths: unkeepPaths, revision: revision)
            case .setItemOverride(let path, let policy):
                return try await applyOverrideChanges([AgentItemOverrideChange(path: path, policy: policy)])
            case .setItemOverrides(let changes):
                return try await applyOverrideChanges(changes)
            case .clearItemOverride(let path):
                return try await applyOverrideChanges([AgentItemOverrideChange(path: path, policy: nil)])
            case .setGlobalPause(let isPaused):
                try await store.setGlobalPause(isPaused, auditEvent: TrashAuditEvent(
                    occurredAt: clock.now(),
                    kind: .globalPauseChanged,
                    detail: isPaused ? "paused" : "resumed"
                ))
                await runtime?.schedulingPolicyDidChange()
                return encode(AgentResponse(payload: .acknowledged))
            case .pauseUntil(let until):
                let now = clock.now()
                guard until.timeIntervalSince1970.isFinite, until > now else { return invalid("The pause end must be in the future.") }
                guard until <= now.addingTimeInterval(Self.maximumFutureSeconds) else { return invalid("The pause end is too far in the future.") }
                try await store.setGlobalPause(true, until: until, auditEvent: TrashAuditEvent(
                    occurredAt: now,
                    kind: .globalPauseChanged,
                    detail: "paused until \(ISO8601DateFormatter().string(from: until))"
                ))
                await runtime?.schedulingPolicyDidChange()
                return encode(AgentResponse(payload: .acknowledged))
            case .loadSettings:
                return encode(AgentResponse(payload: .settings(try await store.loadSettings())))
            case .updateSettings(let requested):
                guard let error = settingsValidationError(for: requested) else {
                    let previous = try await store.loadSettings()
                    if previous != requested {
                        try await store.updateSettings(requested, auditEvent: TrashAuditEvent(
                            occurredAt: clock.now(),
                            kind: .settingsChanged,
                            detail: "defaultGraceSeconds=\(Int(requested.defaultGracePeriodSeconds)); protectHiddenFiles=\(requested.protectHiddenFiles); activityRetentionDays=\(requested.activityRetentionDays)"
                        ))
                        if let runtime {
                            do { try await runtime.policyDidChange() }
                            catch { return encode(AgentResponse(payload: .failure(.storageUnavailable("Settings were saved, but root indexing failed: \(error)")))) }
                        }
                    }
                    return encode(AgentResponse(payload: .settings(try await store.loadSettings())))
                }
                return invalid(error)
            case .itemSize(let path):
                let normalizedPath = RuleScope.normalized(path)
                guard path == normalizedPath, path.hasPrefix("/") else {
                    return invalid("Item paths must be normalized absolute paths.")
                }
                guard let runtime, let measurement = try await runtime.measureItem(path: normalizedPath) else {
                    let snapshot = try await store.loadSnapshot()
                    return await unavailableItem(path: normalizedPath, roots: snapshot.managedRoots)
                }
                return encode(AgentResponse(payload: .itemSize(
                    path: normalizedPath,
                    bytes: measurement.bytes,
                    items: measurement.items,
                    truncated: measurement.truncated
                )))
            case .previewRule(let rule):
                guard let runtime else { return invalid("The indexer is unavailable.") }
                if let error = ruleValidationError(rule) { return invalid("Rule \(rule.name) is invalid: \(error)") }
                do {
                    return encode(AgentResponse(payload: .rulePreview(try await runtime.previewRule(rule))))
                } catch RulePreviewError.invalidRequest(let message) {
                    return invalid(message)
                } catch is CancellationError {
                    return invalid("The preview was cancelled.")
                }
            case .deleteRule(let ruleID):
                try await store.deleteRule(ruleID, auditEvent: TrashAuditEvent(
                    occurredAt: clock.now(),
                    kind: .ruleDeleted,
                    ruleID: ruleID
                ))
                if let runtime { try await runtime.policyDidChange() }
                return encode(AgentResponse(payload: .acknowledged))
            case .rebuildIndex:
                guard let runtime else { return invalid("The indexer is unavailable.") }
                try await runtime.rebuildIndex()
                return encode(AgentResponse(payload: .acknowledged))
            }
        } catch SQLiteSafetyStoreError.revisionConflict {
            return encode(AgentResponse(payload: .failure(.policyConflict)))
        } catch {
            return encode(AgentResponse(payload: .failure(.storageUnavailable(String(describing: error)))))
        }
    }

    private struct ReclaimedTally: Sendable {
        var lifetimeItems = 0
        var lifetimeBytes: Int64 = 0
        var itemsWithKnownSize = 0
        var firstMovedAt: Date?
        var lastMovedAt: Date?
        var dayItems: [Int]
        var dayBytes: [Int64]
    }

    private func reclaimedSummary(now: Date) async throws -> AgentReclaimedSummary {
        let calendar = self.calendar
        let today = calendar.startOfDay(for: now)
        let dates = (-13...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let indexes = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, $0.offset) })
        let initial = ReclaimedTally(
            dayItems: Array(repeating: 0, count: dates.count),
            dayBytes: Array(repeating: 0, count: dates.count)
        )
        let tally = try await store.reduceMovedToTrashEvents(into: initial) { tally, event in
            let items = event.itemCount ?? 1
            let bytes = event.bytes ?? 0
            tally.lifetimeItems += items
            tally.lifetimeBytes += bytes
            if event.bytes != nil { tally.itemsWithKnownSize += items }
            tally.firstMovedAt = min(tally.firstMovedAt ?? event.occurredAt, event.occurredAt)
            tally.lastMovedAt = max(tally.lastMovedAt ?? event.occurredAt, event.occurredAt)
            if let index = indexes[calendar.startOfDay(for: event.occurredAt)] {
                tally.dayItems[index] += items
                tally.dayBytes[index] += bytes
            }
        }
        let days = dates.indices.map { AgentReclaimedDay(day: dates[$0], items: tally.dayItems[$0], bytes: tally.dayBytes[$0]) }
        return AgentReclaimedSummary(
            lifetimeItems: tally.lifetimeItems, lifetimeBytes: tally.lifetimeBytes, itemsWithKnownSize: tally.itemsWithKnownSize,
            firstMovedAt: tally.firstMovedAt, lastMovedAt: tally.lastMovedAt, days: days,
            weekItems: days.suffix(7).reduce(0) { $0 + $1.items },
            weekBytes: days.suffix(7).reduce(0) { $0 + $1.bytes }
        )
    }

    // MARK: - Atomic rule save

    private func saveRule(rule: LifetimeRule, roots: [ManagedRoot]?, keepPaths: [String], unkeepPaths: [String], revision: Int) async throws -> Data {
        let previous = try await store.loadSnapshot()
        guard revision == previous.revision else {
            return encode(AgentResponse(payload: .failure(.policyConflict)))
        }

        var mergedRoots = previous.managedRoots
        for root in roots ?? [] {
            if let index = mergedRoots.firstIndex(where: { $0.id == root.id }) {
                mergedRoots[index] = root
            } else if !mergedRoots.contains(where: { $0.path == root.path }) {
                mergedRoots.append(root)
            }
        }

        var mergedRules = previous.rules
        if let index = mergedRules.firstIndex(where: { $0.id == rule.id }) {
            mergedRules[index] = rule
        } else {
            mergedRules.append(rule)
        }

        let normalizedKeeps = keepPaths.map(RuleScope.normalized)
        let normalizedUnkeeps = unkeepPaths.map(RuleScope.normalized)
        guard Set(normalizedKeeps).isDisjoint(with: normalizedUnkeeps) else {
            return invalid("A path cannot be both kept and un-kept.")
        }

        var overrides = previous.overrides
        var keepOverrides: [ItemPolicyOverride] = []
        for (original, path) in zip(keepPaths, normalizedKeeps) {
            if let error = overridePathError(original, normalized: path, roots: mergedRoots) { return invalid(error) }
            guard let runtime, let candidate = try await runtime.inspectManagedPath(path) else {
                return await unavailableItem(path: path, roots: mergedRoots)
            }
            let protectsDescendants = candidate.kind != .file
            if let existing = previous.overrides.first(where: {
                $0.path == path && $0.identity == candidate.identity && $0.policy == .keep(protectDescendants: protectsDescendants)
            }) {
                keepOverrides.append(existing)
            } else {
                keepOverrides.append(ItemPolicyOverride(identity: candidate.identity, path: path, policy: .keep(protectDescendants: protectsDescendants)))
            }
        }
        for (original, path) in zip(unkeepPaths, normalizedUnkeeps) {
            guard original == path, path.hasPrefix("/") else { return invalid("Override paths must be normalized absolute paths.") }
        }
        let replacedPaths = Set(normalizedKeeps).union(normalizedUnkeeps)
        overrides.removeAll { replacedPaths.contains($0.path) }
        for keep in keepOverrides where !overrides.contains(where: { $0.path == keep.path }) { overrides.append(keep) }

        let updated = AgentPolicySnapshot(
            rules: mergedRules,
            overrides: overrides,
            managedRoots: mergedRoots,
            globallyPaused: previous.globallyPaused,
            pausedUntil: previous.pausedUntil,
            revision: previous.revision
        )
        if let error = validationError(for: updated, existingOverridePaths: Set(previous.overrides.map(\.path))) {
            return invalid(error)
        }
        try await store.replaceSnapshot(
            PolicySnapshot(
                rules: mergedRules,
                overrides: overrides,
                managedRoots: mergedRoots,
                globallyPaused: previous.globallyPaused,
                pausedUntil: previous.pausedUntil
            ),
            auditEvents: mutationEvents(from: previous, to: updated),
            expectedRevision: revision
        )
        if let runtime {
            do { try await runtime.policyDidChange() }
            catch { return encode(AgentResponse(payload: .failure(.storageUnavailable("Rule was saved, but root indexing failed: \(error)")))) }
        }
        return encode(AgentResponse(payload: .acknowledged))
    }

    // MARK: - Overrides

    private func applyOverrideChanges(_ changes: [AgentItemOverrideChange]) async throws -> Data {
        guard !changes.isEmpty else { return encode(AgentResponse(payload: .acknowledged)) }
        let snapshot = try await store.loadSnapshot()
        let now = clock.now()

        // Later changes to the same path win.
        var order: [String] = []
        var byPath: [String: (original: String, policy: ItemOverridePolicy?)] = [:]
        for change in changes {
            let normalized = RuleScope.normalized(change.path)
            if byPath[normalized] == nil { order.append(normalized) }
            byPath[normalized] = (change.path, change.policy)
        }

        var upserts: [ItemPolicyOverride] = []
        var removals: [String] = []
        var events: [TrashAuditEvent] = []
        for path in order {
            guard let entry = byPath[path] else { continue }
            guard entry.original == path, path.hasPrefix("/"), path != "/" else {
                return invalid("Override paths must be normalized absolute paths.")
            }
            guard let policy = entry.policy else {
                guard snapshot.managedRoots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
                    return invalid("The item must be inside a managed folder.")
                }
                if let existing = snapshot.overrides.first(where: { $0.path == path }) {
                    removals.append(path)
                    events.append(TrashAuditEvent(occurredAt: now, kind: .itemUnprotected, identity: existing.identity, detail: path))
                }
                continue
            }
            if let error = overridePathError(entry.original, normalized: path, roots: snapshot.managedRoots) { return invalid(error) }
            if let error = overridePolicyError(policy) { return invalid(error) }
            guard let runtime, let candidate = try await runtime.inspectManagedPath(path) else {
                return await unavailableItem(path: path, roots: snapshot.managedRoots)
            }
            let kind: TrashAuditKind
            switch policy {
            case .inherit: kind = .itemUnprotected
            case .keep: kind = .itemProtected
            case .customExpiry: kind = .expiryChanged
            }
            upserts.append(ItemPolicyOverride(identity: candidate.identity, path: path, policy: policy))
            events.append(TrashAuditEvent(occurredAt: now, kind: kind, identity: candidate.identity, detail: path))
        }
        guard !upserts.isEmpty || !removals.isEmpty else { return encode(AgentResponse(payload: .acknowledged)) }

        try await store.setOverrides(upserts, removingPaths: removals, auditEvents: events)
        if let runtime {
            do { try await runtime.overridesDidChange(paths: upserts.map(\.path) + removals) }
            catch { return encode(AgentResponse(payload: .failure(.storageUnavailable("Overrides were saved, but reconciling the index failed: \(error)")))) }
        }
        return encode(AgentResponse(payload: .acknowledged))
    }

    /// An item is either in a managed folder that is not currently readable (root problem) or not manageable at all.
    private func unavailableItem(path: String, roots: [ManagedRoot]) async -> Data {
        guard let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
            return invalid("The item is not inside an available managed folder.")
        }
        if let statuses = await runtime?.rootStatuses(),
           let status = statuses.first(where: { $0.rootID == root.id }),
           status.state != .watching, status.state != .indexing, status.state != .recovering {
            return encode(AgentResponse(payload: .failure(.rootUnavailable("\(root.path): \(status.state.rawValue)\(status.detail.map { " (\($0))" } ?? "")"))))
        }
        if runtime == nil { return invalid("The indexer is unavailable.") }
        return invalid("The item was not found inside the managed folder.")
    }

    // MARK: - Audit

    private func mutationEvents(from previous: PolicySnapshot, to updated: AgentPolicySnapshot) -> [TrashAuditEvent] {
        let now = clock.now()
        var events: [TrashAuditEvent] = []
        let oldRules = Dictionary(uniqueKeysWithValues: previous.rules.map { ($0.id, $0) })
        let newRules = Dictionary(uniqueKeysWithValues: updated.rules.map { ($0.id, $0) })

        for rule in updated.rules.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let old = oldRules[rule.id] else {
                events.append(TrashAuditEvent(occurredAt: now, kind: .ruleCreated, ruleID: rule.id, detail: rule.name))
                continue
            }
            guard old != rule else { continue }
            let kind: TrashAuditKind = old.state != rule.state && rule.state == .paused ? .rulePaused : .ruleEdited
            events.append(TrashAuditEvent(occurredAt: now, kind: kind, ruleID: rule.id, detail: rule.name))
        }
        for rule in previous.rules where newRules[rule.id] == nil {
            events.append(TrashAuditEvent(occurredAt: now, kind: .ruleDeleted, ruleID: rule.id, detail: rule.name))
        }

        let oldOverrides = Dictionary(previous.overrides.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let newOverrides = Dictionary(updated.overrides.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for path in Set(oldOverrides.keys).union(newOverrides.keys).sorted() {
            let old = oldOverrides[path]
            let new = newOverrides[path]
            guard old != new else { continue }
            let eventKind: TrashAuditKind
            switch new?.policy {
            case .some(.keep): eventKind = .itemProtected
            case .some(.customExpiry): eventKind = .expiryChanged
            case .some(.inherit), .none: eventKind = .itemUnprotected
            }
            events.append(TrashAuditEvent(
                occurredAt: now,
                kind: eventKind,
                identity: new?.identity ?? old?.identity,
                detail: path
            ))
        }
        if previous.globallyPaused != updated.globallyPaused || previous.pausedUntil != updated.pausedUntil {
            let detail: String
            if !updated.globallyPaused { detail = "resumed" }
            else if let until = updated.pausedUntil { detail = "paused until \(ISO8601DateFormatter().string(from: until))" }
            else { detail = "paused" }
            events.append(TrashAuditEvent(occurredAt: now, kind: .globalPauseChanged, detail: detail))
        }
        return events
    }

    private func agentPolicy(from snapshot: PolicySnapshot) -> AgentPolicySnapshot {
        AgentPolicySnapshot(
            rules: snapshot.rules,
            overrides: snapshot.overrides,
            managedRoots: snapshot.managedRoots,
            globallyPaused: snapshot.globallyPaused,
            pausedUntil: snapshot.pausedUntil,
            revision: snapshot.revision
        )
    }

    private func settingsValidationError(for settings: AgentSettings) -> String? {
        guard settings.defaultGracePeriodSeconds.isFinite, settings.defaultGracePeriodSeconds >= 0 else { return "The default grace period must be a non-negative, finite duration." }
        guard settings.defaultGracePeriodSeconds <= 365 * 86_400 else { return "The default grace period cannot exceed 365 days." }
        guard settings.activityRetentionDays <= 3_650 else { return "Activity retention cannot exceed 3650 days." }
        return nil
    }

    private func invalid(_ message: String) -> Data {
        encode(AgentResponse(payload: .failure(.invalidRequest(message))))
    }

    // MARK: - Validation

    /// Dates the agent accepts: finite, after 1970, and no more than ~100 years ahead.
    private static let maximumFutureSeconds: TimeInterval = 100 * 365 * 86_400

    private func isSane(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds > 0 && date <= clock.now().addingTimeInterval(Self.maximumFutureSeconds)
    }

    private func overridePolicyError(_ policy: ItemOverridePolicy) -> String? {
        if case .customExpiry(let date, _) = policy, !isSane(date) {
            return "Custom expiry dates must be finite and within a sensible range."
        }
        return nil
    }

    /// Shared path checks for new or changed overrides: normalized, absolute, inside a managed root, not the root itself.
    private func overridePathError(_ original: String, normalized: String, roots: [ManagedRoot]) -> String? {
        guard original == normalized, normalized.hasPrefix("/"), normalized != "/" else {
            return "Override paths must be normalized absolute paths."
        }
        if roots.contains(where: { $0.path == normalized }) {
            return "An override cannot be set on the managed folder itself; use a rule or pause instead."
        }
        guard roots.contains(where: { normalized.hasPrefix($0.path + "/") }) else {
            return "The item must be inside a managed folder."
        }
        return nil
    }

    /// Structural rule validation shared by replacePolicy, saveRule and previewRule.
    private func ruleValidationError(_ rule: LifetimeRule) -> String? {
        do {
            let scope = try RuleScope(path: rule.scope.path, recursive: rule.scope.recursive)
            guard scope.path == rule.scope.path else { return "Rule scope paths must be normalized absolute paths." }
            let matcher = try ItemMatcher(itemKind: rule.matcher.itemKind, exactNames: rule.matcher.exactNames, globPatterns: rule.matcher.globPatterns)
            let lifetime = try RuleDuration(seconds: rule.lifetime.seconds)
            let gracePeriod = try rule.gracePeriod.map { try RuleDuration(seconds: $0.seconds) }
            guard lifetime.seconds.isFinite, gracePeriod?.seconds.isFinite ?? true else { return "Rule durations must be finite." }
            _ = try LifetimeRule(
                id: rule.id,
                name: rule.name,
                scope: scope,
                matcher: matcher,
                expiryBasis: rule.expiryBasis,
                lifetime: lifetime,
                gracePeriod: gracePeriod,
                action: rule.action,
                state: rule.state,
                matchMode: rule.matchMode
            )
        } catch {
            return "\(error)"
        }
        return nil
    }

    private func validationError(for policy: AgentPolicySnapshot, existingOverridePaths: Set<String>) -> String? {
        var ruleIDs = Set<UUID>()
        var rootIDs = Set<UUID>()
        var rootPaths = Set<String>()
        for root in policy.managedRoots {
            guard rootIDs.insert(root.id).inserted, rootPaths.insert(root.path).inserted else {
                return "Managed root IDs and paths must be unique."
            }
            do {
                _ = try ManagedRoot(id: root.id, displayName: root.displayName, path: root.path, bookmarkData: root.bookmarkData)
            } catch {
                return "Managed root \(root.displayName) is invalid: \(error)"
            }
        }
        for rule in policy.rules {
            guard ruleIDs.insert(rule.id).inserted else { return "Rule IDs must be unique." }
            if let error = ruleValidationError(rule) { return "Rule \(rule.name) is invalid: \(error)" }
            if rule.state == .active, rule.isVeryBroad {
                return "Rule \(rule.name) covers a very broad folder and can only run in Preview."
            }
            if rule.matchMode != .template,
               !policy.managedRoots.contains(where: { rule.scope.path == $0.path || rule.scope.path.hasPrefix($0.path + "/") }) {
                return "Every non-template rule must be inside a bookmarked managed root."
            }
        }

        for override in policy.overrides {
            guard override.path.hasPrefix("/"),
                  override.path != "/",
                  RuleScope.normalized(override.path) == override.path else {
                return "Override paths must be normalized absolute paths below the filesystem root."
            }
            if let identity = override.identity,
               identity.resourceIdentifier.isEmpty || !identity.pathHint.hasPrefix("/") {
                return "Identity-bound overrides require a stable resource ID and an absolute path hint."
            }
            if let error = overridePolicyError(override.policy) { return error }
            if !existingOverridePaths.contains(override.path), rootPaths.contains(override.path) {
                return "An override cannot be set on the managed folder itself."
            }
        }
        if let until = policy.pausedUntil, !until.timeIntervalSince1970.isFinite {
            return "The pause end must be a finite date."
        }
        return nil
    }

    private func encode(_ response: AgentResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}
