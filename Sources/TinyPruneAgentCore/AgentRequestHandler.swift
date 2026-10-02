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

    public init(store: SQLiteSafetyStore, runtime: ManagedRootAgentRuntime? = nil, serviceVersion: String = "0.1.0", clock: any SafetyClock = SystemSafetyClock()) {
        self.store = store
        self.runtime = runtime
        self.serviceVersion = serviceVersion
        self.clock = clock
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

        do {
            switch request.operation {
            case .health:
                return encode(AgentResponse(payload: .health(AgentHealth(serviceVersion: serviceVersion))))
            case .loadPolicy:
                let snapshot = try await store.loadSnapshot()
                return encode(AgentResponse(payload: .policy(agentPolicy(from: snapshot))))
            case .loadOverview:
                let snapshot = try await store.loadSnapshot()
                let upcoming = try await store.upcomingDeadlines(limit: 200).map { AgentUpcomingItem(explanation: $0.explanation) }
                let stats = try await store.deadlineCountsByRule(now: Date()).map { AgentRuleStats(ruleID: $0.key, matches: $0.value.matches, due: $0.value.due) }
                return encode(AgentResponse(payload: .overview(AgentOverviewSnapshot(
                    policy: agentPolicy(from: snapshot),
                    upcoming: upcoming,
                    ruleStats: stats,
                    indexedItems: try await store.indexedDeadlineCount(),
                    databaseBytes: await store.databaseSizeBytes()
                ))))
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
                        detail: event.detail
                    )
                }
                return encode(AgentResponse(payload: .activity(activity)))
            case .explainItem(let path):
                let normalizedPath = RuleScope.normalized(path)
                guard path == normalizedPath, path.hasPrefix("/") else {
                    return invalid("Item paths must be normalized absolute paths.")
                }
                guard let runtime, let candidate = try await runtime.inspectManagedPath(normalizedPath) else {
                    return invalid("The item is not inside an available managed folder.")
                }
                let snapshot = try await store.loadSnapshot()
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
                if let error = validationError(for: policy) {
                    return encode(AgentResponse(payload: .failure(.invalidRequest(error))))
                }
                let previous = try await store.loadSnapshot()
                try await store.replaceSnapshot(
                    PolicySnapshot(
                        rules: policy.rules,
                        overrides: policy.overrides,
                        managedRoots: policy.managedRoots,
                        globallyPaused: policy.globallyPaused,
                        pausedUntil: policy.pausedUntil
                    ),
                    auditEvents: mutationEvents(from: previous, to: policy)
                )
                if let runtime {
                    do { try await runtime.policyDidChange() }
                    catch { return encode(AgentResponse(payload: .failure(.storageUnavailable("Policy was saved, but root indexing failed: \(error)")))) }
                }
                return encode(AgentResponse(payload: .acknowledged))
            case .setItemOverride(let path, let policy):
                let normalizedPath = RuleScope.normalized(path)
                guard path == normalizedPath, path.hasPrefix("/") else {
                    return invalid("Override paths must be normalized absolute paths.")
                }
                guard let runtime,
                      let candidate = try await runtime.inspectManagedPath(normalizedPath) else {
                    return invalid("The item must be inside an available managed folder.")
                }
                let kind: TrashAuditKind
                switch policy {
                case .inherit: kind = .itemUnprotected
                case .keep: kind = .itemProtected
                case .customExpiry: kind = .expiryChanged
                }
                let override = ItemPolicyOverride(identity: candidate.identity, path: normalizedPath, policy: policy)
                try await store.setOverride(override, auditEvent: TrashAuditEvent(
                    occurredAt: Date(),
                    kind: kind,
                    identity: candidate.identity,
                    detail: normalizedPath
                ))
                if case .customExpiry = policy {
                    try await runtime.reconcileItemOverride(at: normalizedPath)
                } else {
                    try await runtime.policyDidChange()
                }
                return encode(AgentResponse(payload: .acknowledged))
            case .clearItemOverride(let path):
                let normalizedPath = RuleScope.normalized(path)
                guard path == normalizedPath, path.hasPrefix("/") else {
                    return invalid("Override paths must be normalized absolute paths.")
                }
                let snapshot = try await store.loadSnapshot()
                guard snapshot.managedRoots.contains(where: { normalizedPath == $0.path || normalizedPath.hasPrefix($0.path + "/") }) else {
                    return invalid("The item must be inside a managed folder.")
                }
                try await store.removeOverrides(at: normalizedPath, auditEvent: TrashAuditEvent(
                    occurredAt: Date(),
                    kind: .itemUnprotected,
                    detail: normalizedPath
                ))
                if let runtime { try await runtime.policyDidChange() }
                return encode(AgentResponse(payload: .acknowledged))
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
                guard until > now else { return invalid("The pause end must be in the future.") }
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
                    return invalid("The item is not inside an available managed folder.")
                }
                return encode(AgentResponse(payload: .itemSize(
                    path: normalizedPath,
                    bytes: measurement.bytes,
                    items: measurement.items,
                    truncated: measurement.truncated
                )))
            case .previewRule(let rule):
                guard let runtime else { return invalid("The indexer is unavailable.") }
                do {
                    return encode(AgentResponse(payload: .rulePreview(try await runtime.previewRule(rule))))
                } catch RulePreviewError.invalidRequest(let message) {
                    return invalid(message)
                }
            case .deleteRule(let ruleID):
                try await store.deleteRule(ruleID, auditEvent: TrashAuditEvent(
                    occurredAt: Date(),
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
        } catch {
            return encode(AgentResponse(payload: .failure(.storageUnavailable(String(describing: error)))))
        }
    }
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
            pausedUntil: snapshot.pausedUntil
        )
    }

    private func settingsValidationError(for settings: AgentSettings) -> String? {
        guard settings.defaultGracePeriodSeconds <= 365 * 86_400 else { return "The default grace period cannot exceed 365 days." }
        guard settings.activityRetentionDays <= 3_650 else { return "Activity retention cannot exceed 3650 days." }
        return nil
    }

    private func invalid(_ message: String) -> Data {
        encode(AgentResponse(payload: .failure(.invalidRequest(message))))
    }

    private func validationError(for policy: AgentPolicySnapshot) -> String? {
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
            do {
                let scope = try RuleScope(path: rule.scope.path, recursive: rule.scope.recursive)
                guard scope.path == rule.scope.path else { return "Rule scope paths must be normalized absolute paths." }
                let matcher = try ItemMatcher(itemKind: rule.matcher.itemKind, exactNames: rule.matcher.exactNames, globPatterns: rule.matcher.globPatterns)
                let lifetime = try RuleDuration(seconds: rule.lifetime.seconds)
                let gracePeriod = try rule.gracePeriod.map { try RuleDuration(seconds: $0.seconds) }
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
                return "Rule \(rule.name) is invalid: \(error)"
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
            if case .customExpiry(let date, _) = override.policy, !date.timeIntervalSince1970.isFinite {
                return "Custom expiry dates must be finite."
            }
        }
        return nil
    }

    private func encode(_ response: AgentResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}
