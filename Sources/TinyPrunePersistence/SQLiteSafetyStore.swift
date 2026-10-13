import CSQLite
import Foundation
import TinyPruneDomain
import TinyPruneEngine

public struct PersistedDeadline: Hashable, Codable, Sendable {
    public let identity: FilesystemIdentity
    public let scheduledAt: Date
    public let explanation: CandidateExplanation
    public var source: ScheduledSource {
        if let overrideID = explanation.customOverrideID { return .customOverride(overrideID) }
        return .rule(explanation.matchedRuleID)
    }
    public init(identity: FilesystemIdentity, scheduledAt: Date, explanation: CandidateExplanation) {
        self.identity = identity
        self.scheduledAt = scheduledAt
        self.explanation = explanation
    }
}

public struct PersistedObservedActivity: Hashable, Sendable {
    public let identity: FilesystemIdentity
    public let firstObservedAt: Date
    public let lastObservedAt: Date

    public init(identity: FilesystemIdentity, firstObservedAt: Date, lastObservedAt: Date) {
        self.identity = identity
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

public struct PersistedProjectActivity: Hashable, Sendable {
    public let identity: FilesystemIdentity
    public let lastActivityAt: Date

    public init(identity: FilesystemIdentity, lastActivityAt: Date) {
        self.identity = identity
        self.lastActivityAt = lastActivityAt
    }
}

public struct ProjectActivityObservation: Hashable, Sendable {
    public let path: String
    public let modifiedAt: Date

    public init(path: String, modifiedAt: Date) {
        self.path = RuleScope.normalized(path)
        self.modifiedAt = modifiedAt
    }
}

public struct PersistedDeadlinePage: Sendable {
    public let deadlines: [PersistedDeadline]
    public let nextCursor: String?

    public init(deadlines: [PersistedDeadline], nextCursor: String?) {
        self.deadlines = deadlines
        self.nextCursor = nextCursor
    }
}

public struct PersistedUpcomingCursor: Codable, Equatable, Sendable {
    public let scheduledAt: Date
    public let identityKey: String
    public init(scheduledAt: Date, identityKey: String) {
        self.scheduledAt = scheduledAt
        self.identityKey = identityKey
    }
}

public struct PersistedUpcomingPage: Sendable {
    public let deadlines: [PersistedDeadline]
    public let nextCursor: PersistedUpcomingCursor?
    public let totalCount: Int
}

public struct PersistedDeadlineSummary: Sendable {
    public let active: Int
    public let preview: Int
    public let activeSoon: Int
}

public struct PersistedOverviewSnapshot: Sendable {
    public let policy: PolicySnapshot
    public let upcoming: [PersistedDeadline]
    public let summary: PersistedDeadlineSummary
    public let ruleCounts: [UUID: (matches: Int, due: Int)]
    public let indexedItems: Int
}

public struct PersistedCandidatePage: Sendable {
    public let candidates: [RuleCandidate]
    public let nextCursor: String?
}

public struct PersistedReclaimedTotals: Sendable {
    public let lifetimeItems: Int
    public let lifetimeBytes: Int64
    public let itemsWithKnownSize: Int
    public let firstMovedAt: Date?
    public let lastMovedAt: Date?
}

public struct PersistedReclaimedDay: Sendable {
    public let items: Int
    public let bytes: Int64
}

public struct PersistedReclaimedSnapshot: Sendable {
    public let totals: PersistedReclaimedTotals
    public let days: [PersistedReclaimedDay]
}

public enum SQLiteSafetyStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case encodingFailed(String)
    /// `replaceSnapshot` was given an expected revision that no longer matches the stored policy.
    case revisionConflict
}

public actor SQLiteSafetyStore: PolicySnapshotProviding, TrashAuditRecording {
    public let databaseURL: URL
    nonisolated(unsafe) private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let clock: any SafetyClock
    /// Project-activity scans currently in flight; observation rows of any other scan id are orphans.
    private var activeProjectScans: Set<String> = []

    public init(databaseURL: URL, clock: any SafetyClock = SystemSafetyClock()) throws {
        self.databaseURL = databaseURL
        self.clock = clock
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        encoder.outputFormatting = [.sortedKeys]
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, database != nil else {
            let reason = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed with code \(result)"
            if let database { sqlite3_close(database) }
            database = nil
            throw SQLiteSafetyStoreError.openFailed(reason)
        }
        sqlite3_busy_timeout(database, 5_000)
        try Self.migrate(database!)
        try Self.execute(database!, "PRAGMA journal_mode=WAL")
        try Self.execute(database!, "PRAGMA synchronous=FULL")
        // Identities derived from device numbers (`np:` keys) are not stable across restarts or remounts; drop them.
        try Self.execute(database!, "DELETE FROM deadlines WHERE identity_key LIKE 'np:%'")
        try Self.execute(database!, "DELETE FROM observed_activity WHERE identity_key LIKE 'np:%'")
        try Self.execute(database!, "DELETE FROM project_activity WHERE identity_key LIKE 'np:%'")
        try Self.execute(database!, "DELETE FROM staged_candidates; DELETE FROM staged_deadlines; DELETE FROM candidate_scans; DELETE FROM staged_projects; DELETE FROM project_activity_observations")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func loadSnapshot() async throws -> PolicySnapshot {
        try readPolicySnapshot()
    }

    private func readPolicySnapshot() throws -> PolicySnapshot {
        try lapseExpiredPause()
        // One read transaction: rules, overrides, roots, settings and revision are a single consistent view.
        try execute("BEGIN")
        do {
            let rules = try loadPayloads(table: "rules", as: LifetimeRule.self)
            let overrides = try loadPayloads(table: "item_overrides", as: ItemPolicyOverride.self)
            let managedRoots = try loadPayloads(table: "managed_roots", as: ManagedRoot.self)
            let state = try loadSettingsRow()
            let revision = try currentPolicyRevision()
            try execute("COMMIT")
            let now = clock.now()
            let pausedUntil = state.pausedUntil.flatMap { $0 > now ? $0 : nil }
            let effectivelyPaused = state.globallyPaused && (state.pausedUntil == nil || pausedUntil != nil)
            return PolicySnapshot(
                rules: rules,
                overrides: overrides,
                managedRoots: managedRoots,
                globallyPaused: effectivelyPaused,
                pausedUntil: effectivelyPaused ? pausedUntil : nil,
                settings: state.settings,
                revision: revision
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func currentPolicyRevision() throws -> Int {
        let statement = try prepare("SELECT policy_revision FROM settings WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard try rowAvailable(statement) else {
            throw SQLiteSafetyStoreError.statementFailed("settings row is missing")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Must be called inside the transaction that performs the policy mutation.
    private func bumpPolicyRevision() throws {
        try execute("UPDATE settings SET policy_revision = policy_revision + 1 WHERE id = 1")
    }

    public func loadSettings() async throws -> AgentSettings {
        try loadSettingsRow().settings
    }

    /// Persists settings and audits the change in one transaction, then applies retention (keeping the new event).
    public func updateSettings(_ settings: AgentSettings, auditEvent: TrashAuditEvent) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE settings SET default_grace_seconds = ?, protect_hidden_files = ?, activity_retention_days = ? WHERE id = 1")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_double(statement, 1, settings.defaultGracePeriodSeconds))
            try check(sqlite3_bind_int(statement, 2, settings.protectHiddenFiles ? 1 : 0))
            try check(sqlite3_bind_int64(statement, 3, Int64(settings.activityRetentionDays)))
            try stepDone(statement)
            try bumpPolicyRevision()
            try insertAuditEvent(auditEvent)
            try pruneAuditEvents(retentionDays: settings.activityRetentionDays, keeping: auditEvent.id)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private struct SettingsRow {
        let globallyPaused: Bool
        let pausedUntil: Date?
        let settings: AgentSettings
    }

    private func loadSettingsRow() throws -> SettingsRow {
        let statement = try prepare("SELECT globally_paused, pause_until, default_grace_seconds, protect_hidden_files, activity_retention_days FROM settings WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteSafetyStoreError.statementFailed("global pause setting is missing")
        }
        let until = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        return SettingsRow(
            globallyPaused: sqlite3_column_int(statement, 0) != 0,
            pausedUntil: until,
            settings: AgentSettings(
                defaultGracePeriodSeconds: sqlite3_column_double(statement, 2),
                protectHiddenFiles: sqlite3_column_int(statement, 3) != 0,
                activityRetentionDays: Int(sqlite3_column_int64(statement, 4))
            )
        )
    }

    /// Clears a timed pause whose end has passed and records one `globalPauseChanged` event for it.
    /// The conditional UPDATE inside the transaction makes the lapse (and its audit) happen exactly once.
    private func lapseExpiredPause() throws {
        let now = clock.now()
        let probe = try prepare("SELECT 1 FROM settings WHERE id = 1 AND globally_paused = 1 AND pause_until IS NOT NULL AND pause_until <= ?")
        let lapsed: Bool
        do {
            defer { sqlite3_finalize(probe) }
            try check(sqlite3_bind_double(probe, 1, now.timeIntervalSince1970))
            lapsed = try rowAvailable(probe)
        }
        guard lapsed else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE settings SET globally_paused = 0, pause_until = NULL WHERE id = 1 AND globally_paused = 1 AND pause_until IS NOT NULL AND pause_until <= ?")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_double(statement, 1, now.timeIntervalSince1970))
            try stepDone(statement)
            if sqlite3_changes(database) == 1 {
                try insertAuditEvent(TrashAuditEvent(occurredAt: now, kind: .globalPauseChanged, detail: "resumed automatically"))
                try bumpPolicyRevision()
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func pruneAuditEvents(retentionDays: Int, keeping keptID: UUID? = nil) throws {
        guard retentionDays > 0 else { return }
        let cutoff = clock.now().addingTimeInterval(-Double(retentionDays) * 86_400)
        // Successful moves are the durable lifetime ledger, independent of Activity retention.
        let statement = try prepare("DELETE FROM audit_events WHERE occurred_at < ? AND id <> ? AND kind <> 'movedToTrash'")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970))
        try bind(keptID?.uuidString ?? "", to: statement, at: 2)
        try stepDone(statement)
    }

    /// Replaces the whole policy atomically. When `expectedRevision` is given and no longer matches the stored
    /// revision (checked inside the write transaction) nothing is written and `revisionConflict` is thrown.
    public func replaceSnapshot(_ snapshot: PolicySnapshot, auditEvents: [TrashAuditEvent] = [], expectedRevision: Int? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if let expectedRevision, try currentPolicyRevision() != expectedRevision {
                throw SQLiteSafetyStoreError.revisionConflict
            }
            try execute("DELETE FROM rules")
            try execute("DELETE FROM item_overrides")
            try execute("DELETE FROM managed_roots")
            for (position, rule) in snapshot.rules.enumerated() {
                try insertPayload(table: "rules", id: rule.id.uuidString, position: position, value: rule)
            }
            for (position, override) in snapshot.overrides.enumerated() {
                try insertPayload(table: "item_overrides", id: override.id.uuidString, position: position, value: override)
            }
            for (position, root) in snapshot.managedRoots.enumerated() {
                try insertPayload(table: "managed_roots", id: root.id.uuidString, position: position, value: root)
            }
            let statement = try prepare("UPDATE settings SET globally_paused = ?, pause_until = ? WHERE id = 1")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_int(statement, 1, snapshot.globallyPaused ? 1 : 0))
            if snapshot.globallyPaused, let until = snapshot.pausedUntil {
                try check(sqlite3_bind_double(statement, 2, until.timeIntervalSince1970))
            } else {
                try check(sqlite3_bind_null(statement, 2))
            }
            try stepDone(statement)
            try bumpPolicyRevision()
            try insertAuditEvent(TrashAuditEvent(
                occurredAt: clock.now(),
                kind: .policyReplaced,
                detail: "rules=\(snapshot.rules.count); overrides=\(snapshot.overrides.count); roots=\(snapshot.managedRoots.count); globallyPaused=\(snapshot.globallyPaused)"
            ))
            for event in auditEvents { try insertAuditEvent(event) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func setOverride(_ override: ItemPolicyOverride, auditEvent: TrashAuditEvent) throws {
        try setOverrides([override], removingPaths: [], auditEvents: [auditEvent])
    }

    public func removeOverrides(at path: String, auditEvent: TrashAuditEvent) throws {
        try setOverrides([], removingPaths: [path], auditEvents: [auditEvent])
    }

    /// Applies a batch of override upserts and removals in one transaction (read-modify-write happens inside it).
    /// An upsert replaces any existing override at the same normalized path; later upserts win over earlier ones.
    public func setOverrides(_ upserts: [ItemPolicyOverride], removingPaths: [String], auditEvents: [TrashAuditEvent]) throws {
        let removed = Set(removingPaths.map(RuleScope.normalized))
        try execute("BEGIN IMMEDIATE")
        do {
            var overrides = try loadPayloads(table: "item_overrides", as: ItemPolicyOverride.self)
            overrides.removeAll { removed.contains($0.path) }
            for upsert in upserts {
                overrides.removeAll { $0.path == upsert.path }
                overrides.append(upsert)
            }
            try execute("DELETE FROM item_overrides")
            for (position, override) in overrides.enumerated() {
                try insertPayload(table: "item_overrides", id: override.id.uuidString, position: position, value: override)
            }
            try bumpPolicyRevision()
            for event in auditEvents { try insertAuditEvent(event) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func setGlobalPause(_ isPaused: Bool, until: Date? = nil, auditEvent: TrashAuditEvent) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE settings SET globally_paused = ?, pause_until = ? WHERE id = 1")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_int(statement, 1, isPaused ? 1 : 0))
            if isPaused, let until {
                try check(sqlite3_bind_double(statement, 2, until.timeIntervalSince1970))
            } else {
                try check(sqlite3_bind_null(statement, 2))
            }
            try stepDone(statement)
            try bumpPolicyRevision()
            try insertAuditEvent(auditEvent)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func deleteRule(_ ruleID: UUID, auditEvent: TrashAuditEvent) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("DELETE FROM rules WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(ruleID.uuidString, to: statement, at: 1)
            try stepDone(statement)
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteSafetyStoreError.statementFailed("rule does not exist")
            }
            let deadlines = try prepare("DELETE FROM deadlines WHERE rule_id = ?")
            defer { sqlite3_finalize(deadlines) }
            try bind(ruleID.uuidString, to: deadlines, at: 1)
            try stepDone(deadlines)
            try bumpPolicyRevision()
            try insertAuditEvent(auditEvent)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func append(_ event: TrashAuditEvent) async throws {
        try insertAuditEvent(event)
    }

    private func insertAuditEvent(_ event: TrashAuditEvent) throws {
        let statement = try prepare("INSERT INTO audit_events(id, occurred_at, kind, payload) VALUES(?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(event.id.uuidString, to: statement, at: 1)
        try check(sqlite3_bind_double(statement, 2, event.occurredAt.timeIntervalSince1970))
        try bind(event.kind.rawValue, to: statement, at: 3)
        try bind(try encode(event), to: statement, at: 4)
        try stepDone(statement)
    }

    public func auditEvents(limit: Int = 1_000) throws -> [TrashAuditEvent] {
        let statement = try prepare("SELECT payload FROM audit_events ORDER BY occurred_at DESC, id DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, Int64(max(0, limit))))
        var result: [TrashAuditEvent] = []
        while try rowAvailable(statement) {
            result.append(try decode(TrashAuditEvent.self, from: columnData(statement, at: 0)))
        }
        return result
    }


    /// Replaces the stored security-scoped bookmark of a managed root after the agent re-resolved a stale one.
    public func updateManagedRootBookmark(rootID: UUID, bookmarkData: Data, auditEvent: TrashAuditEvent?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let select = try prepare("SELECT payload FROM managed_roots WHERE id = ?")
            defer { sqlite3_finalize(select) }
            try bind(rootID.uuidString, to: select, at: 1)
            guard try rowAvailable(select) else {
                throw SQLiteSafetyStoreError.statementFailed("managed root does not exist")
            }
            let current = try decode(ManagedRoot.self, from: columnData(select, at: 0))
            let refreshed: ManagedRoot
            do {
                refreshed = try ManagedRoot(id: current.id, displayName: current.displayName, path: current.path, bookmarkData: bookmarkData)
            } catch {
                throw SQLiteSafetyStoreError.encodingFailed("refreshed bookmark rejected: \(error)")
            }
            let update = try prepare("UPDATE managed_roots SET payload = ? WHERE id = ?")
            defer { sqlite3_finalize(update) }
            try bind(try encode(refreshed), to: update, at: 1)
            try bind(rootID.uuidString, to: update, at: 2)
            try stepDone(update)
            try bumpPolicyRevision()
            if let auditEvent { try insertAuditEvent(auditEvent) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Startup reconciliation: a `trashAttempted` event with no later `movedToTrash`/`trashFailed` for the same
    /// identity means the agent stopped mid-operation. Records a `trashFailed` event for each so the audit log
    /// never claims an attempt is still in flight. Idempotent. Returns the number of attempts reconciled.
    @discardableResult
    public func reconcileInterruptedTrashAttempts() throws -> Int {
        let statement = try prepare("SELECT payload FROM audit_events WHERE kind IN ('trashAttempted', 'movedToTrash', 'trashFailed') ORDER BY occurred_at ASC, rowid ASC")
        var latest: [String: TrashAuditEvent] = [:]
        do {
            defer { sqlite3_finalize(statement) }
            while try rowAvailable(statement) {
                let event = try decode(TrashAuditEvent.self, from: columnData(statement, at: 0))
                guard let identity = event.identity else { continue }
                latest[Self.identityKey(identity)] = event
            }
        }
        let dangling = latest.values.filter { $0.kind == .trashAttempted }.sorted { $0.occurredAt < $1.occurredAt }
        guard !dangling.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE")
        do {
            let now = clock.now()
            for attempt in dangling {
                try insertAuditEvent(TrashAuditEvent(
                    occurredAt: now,
                    kind: .trashFailed,
                    identity: attempt.identity,
                    ruleID: attempt.ruleID,
                    detail: "interrupted before the outcome was recorded; the item may or may not have been moved to Trash"
                ))
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return dangling.count
    }

    public func saveDeadline(_ deadline: PersistedDeadline) throws {
        let statement = try deadlineWriteStatement()
        defer { sqlite3_finalize(statement) }
        try persistDeadline(deadline, statement:statement)
    }

    public func saveDeadlines(_ deadlines: [PersistedDeadline]) throws {
        guard !deadlines.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try deadlineWriteStatement()
            defer { sqlite3_finalize(statement) }
            var changed = false
            for deadline in deadlines {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try persistDeadline(deadline,statement:statement)
                changed = changed || sqlite3_changes(database) > 0
            }
            try execute(changed ? "COMMIT" : "ROLLBACK")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func deadlineWriteStatement() throws -> OpaquePointer {
        try prepare("""
        INSERT INTO deadlines(identity_key, scheduled_at, path_hint, payload, rule_id, disposition, expiry_basis) VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(identity_key) DO UPDATE SET scheduled_at=excluded.scheduled_at, path_hint=excluded.path_hint, payload=excluded.payload, rule_id=excluded.rule_id, disposition=excluded.disposition, expiry_basis=excluded.expiry_basis
        WHERE deadlines.payload <> excluded.payload
        """)
    }

    private func persistDeadline(_ deadline: PersistedDeadline, statement: OpaquePointer) throws {
        try bind(Self.identityKey(deadline.identity), to: statement, at: 1)
        try check(sqlite3_bind_double(statement, 2, deadline.scheduledAt.timeIntervalSince1970))
        try bind(deadline.identity.pathHint, to: statement, at: 3)
        try bind(try encode(deadline), to: statement, at: 4)
        if deadline.explanation.customOverrideID == nil {
            try bind(deadline.explanation.matchedRuleID.uuidString, to: statement, at: 5)
        } else {
            try check(sqlite3_bind_null(statement, 5))
        }
        try bind(deadline.explanation.disposition.rawValue, to: statement, at: 6)
        try bind(deadline.explanation.expiryBasis.rawValue, to: statement, at: 7)
        try stepDone(statement)
    }

    /// Unconditional removal: for callers that are authoritative about the item no longer being eligible
    /// (the indexer after re-evaluating it, or rule removal). A scheduler that merely finished executing a
    /// deadline it read earlier must use `removeDeadline(for:scheduledAt:)` so a fresher row survives.
    public func removeDeadline(for identity: FilesystemIdentity) throws {
        let statement = try prepare("DELETE FROM deadlines WHERE identity_key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(identity), to: statement, at: 1)
        try stepDone(statement)
    }

    /// Removes the deadline only if it still has the `scheduledAt` the caller acted on; returns whether a row was deleted.
    @discardableResult
    public func removeDeadline(for identity: FilesystemIdentity, scheduledAt: Date) throws -> Bool {
        let statement = try prepare("DELETE FROM deadlines WHERE identity_key = ? AND scheduled_at = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(identity), to: statement, at: 1)
        try check(sqlite3_bind_double(statement, 2, scheduledAt.timeIntervalSince1970))
        try stepDone(statement)
        return sqlite3_changes(database) > 0
    }
    public func removeDeadlines(atOrBelow path: String) throws {
        let root = RuleScope.normalized(path)
        let statement = try prepare("DELETE FROM deadlines WHERE path_hint = ? OR (path_hint >= ? AND path_hint < ?)")
        defer { sqlite3_finalize(statement) }
        try bind(root, to: statement, at: 1)
        try bind(root + "/", to: statement, at: 2)
        try bind(root + "0", to: statement, at: 3)
        try stepDone(statement)
    }

    /// Removing an ancestor root must not discard identities still managed by a nested root.
    public func removeUnmanagedState(atOrBelow path: String, retaining rootPaths: [String]) throws {
        let root = RuleScope.normalized(path)
        let retained = rootPaths.compactMap { path -> String? in
            let normalized = RuleScope.normalized(path)
            return normalized == root || normalized.hasPrefix(root + "/") ? normalized : nil
        }
        let exclusions = String(repeating: " AND NOT (path_hint=? OR (path_hint>=? AND path_hint<?))", count: retained.count)
        let prefixes = [root] + retained
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["deadlines", "observed_activity", "project_activity"] {
                let statement = try prepare("DELETE FROM \(table) WHERE (path_hint=? OR (path_hint>=? AND path_hint<?))" + exclusions)
                defer { sqlite3_finalize(statement) }
                for (index, prefix) in prefixes.enumerated() {
                    let position = Int32(index * 3 + 1)
                    try bind(prefix, to: statement, at: position)
                    try bind(prefix + "/", to: statement, at: position + 1)
                    try bind(prefix + "0", to: statement, at: position + 2)
                }
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func observedActivity(for identity: FilesystemIdentity) throws -> PersistedObservedActivity? {
        let statement = try prepare("SELECT first_observed_at, last_observed_at, path_hint FROM observed_activity WHERE identity_key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(identity), to: statement, at: 1)
        guard try rowAvailable(statement) else { return nil }
        return PersistedObservedActivity(
            identity: FilesystemIdentity(
                volumeIdentifier: identity.volumeIdentifier,
                resourceIdentifier: identity.resourceIdentifier,
                pathHint: String(cString: sqlite3_column_text(statement, 2)),
                creationTime: identity.creationTime,
                generation: identity.generation,
                isPersistent: identity.isPersistent
            ),
            firstObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        )
    }


    public func recordObservedActivity(identity: FilesystemIdentity, at date: Date) throws {
        let statement = try prepare("""
        INSERT INTO observed_activity(identity_key, path_hint, first_observed_at, last_observed_at) VALUES(?, ?, ?, ?)
        ON CONFLICT(identity_key) DO UPDATE SET path_hint=excluded.path_hint, last_observed_at=MAX(observed_activity.last_observed_at,excluded.last_observed_at)
        """)
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(identity), to: statement, at: 1)
        try bind(identity.pathHint, to: statement, at: 2)
        try check(sqlite3_bind_double(statement, 3, date.timeIntervalSince1970))
        try check(sqlite3_bind_double(statement, 4, date.timeIntervalSince1970))
        try stepDone(statement)
    }

    public func removeObservedActivity(atOrBelow path: String) throws {
        let root = RuleScope.normalized(path)
        let statement = try prepare("DELETE FROM observed_activity WHERE path_hint = ? OR (path_hint >= ? AND path_hint < ?)")
        defer { sqlite3_finalize(statement) }
        try bind(root, to: statement, at: 1)
        try bind(root + "/", to: statement, at: 2)
        try bind(root + "0", to: statement, at: 3)
        try stepDone(statement)
    }

    public func recordInitialObservations(_ activities: [PersistedObservedActivity]) throws {
        guard !activities.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
            INSERT INTO observed_activity(identity_key, path_hint, first_observed_at, last_observed_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(identity_key) DO UPDATE SET path_hint=excluded.path_hint
            WHERE observed_activity.path_hint <> excluded.path_hint
            """)
            defer { sqlite3_finalize(statement) }
            for activity in activities {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(Self.identityKey(activity.identity), to: statement, at: 1)
                try bind(activity.identity.pathHint, to: statement, at: 2)
                try check(sqlite3_bind_double(statement, 3, activity.firstObservedAt.timeIntervalSince1970))
                try check(sqlite3_bind_double(statement, 4, activity.lastObservedAt.timeIntervalSince1970))
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func eventCursor(for rootID: UUID) throws -> UInt64? {
        let statement = try prepare("SELECT event_id FROM event_cursors WHERE root_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(rootID.uuidString, to: statement, at: 1)
        guard try rowAvailable(statement) else { return nil }
        let text = String(cString: sqlite3_column_text(statement, 0))
        guard let eventID = UInt64(text) else {
            throw SQLiteSafetyStoreError.statementFailed("invalid FSEvents cursor for \(rootID)")
        }
        return eventID
    }

    public func saveEventCursor(for rootID: UUID, eventID: UInt64) throws {
        let statement = try prepare("""
        INSERT INTO event_cursors(root_id, event_id) VALUES(?, ?)
        ON CONFLICT(root_id) DO UPDATE SET event_id=excluded.event_id
        """)
        defer { sqlite3_finalize(statement) }
        try bind(rootID.uuidString, to: statement, at: 1)
        try bind(String(eventID), to: statement, at: 2)
        try stepDone(statement)
    }

    public func reconcileObservedActivity(identity: FilesystemIdentity, through date: Date) throws {
        let statement = try prepare("""
        UPDATE observed_activity
        SET last_observed_at=MAX(last_observed_at, ?)
        WHERE identity_key = ?
        """)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, date.timeIntervalSince1970))
        try bind(Self.identityKey(identity), to: statement, at: 2)
        try stepDone(statement)
    }

    public func removeEventCursor(for rootID: UUID) throws {
        let statement = try prepare("DELETE FROM event_cursors WHERE root_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(rootID.uuidString, to: statement, at: 1)
        try stepDone(statement)
    }

    public func performMaintenance() throws {
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
        try pruneAuditEvents(retentionDays: loadSettingsRow().settings.activityRetentionDays)
        try execute("PRAGMA optimize")
    }

    /// Crash leftovers are cleared at connection startup; live scans remain isolated by scan ID.
    public func beginProjectActivityScan() throws -> String {
        let scanID = UUID().uuidString
        activeProjectScans.insert(scanID)
        return scanID
    }

    /// Releases a scan that ended without `finishProjectActivityScan` (cancelled or failed).
    public func endProjectActivityScan(scanID: String) throws {
        activeProjectScans.remove(scanID)
        for table in ["project_activity_observations","staged_projects"] {
            let delete = try prepare("DELETE FROM \(table) WHERE scan_id=?")
            defer { sqlite3_finalize(delete) }
            try bind(scanID,to:delete,at:1); try stepDone(delete)
        }
    }

    public func recordProjectActivities(_ projects: [PersistedProjectActivity], scanID: String) throws {
        guard !projects.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
            INSERT INTO staged_projects(identity_key, path_hint, last_activity_at, scan_id)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(scan_id,identity_key) DO UPDATE SET
                path_hint=excluded.path_hint,
                last_activity_at=MAX(staged_projects.last_activity_at, excluded.last_activity_at)
            """)
            defer { sqlite3_finalize(statement) }
            for project in projects {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(Self.identityKey(project.identity), to: statement, at: 1)
                try bind(project.identity.pathHint, to: statement, at: 2)
                try check(sqlite3_bind_double(statement, 3, project.lastActivityAt.timeIntervalSince1970))
                try bind(scanID, to: statement, at: 4)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func recordProjectObservations(_ observations: [ProjectActivityObservation], scanID: String) throws {
        guard !observations.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO project_activity_observations(scan_id, path_hint, modified_at) VALUES(?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            for observation in observations {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(scanID, to: statement, at: 1)
                try bind(observation.path, to: statement, at: 2)
                try check(sqlite3_bind_double(statement, 3, observation.modifiedAt.timeIntervalSince1970))
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func finishProjectActivityScan(scanID: String, atOrBelow path: String) async throws {
        let root = RuleScope.normalized(path)
        var projectCursor = ""
        var maxima: [(key: String, date: Double)] = []
        maxima.reserveCapacity(256)
        while let project = try nextStagedProject(scanID: scanID, after: projectCursor) {
            projectCursor = project.key
            let children = try prepare("SELECT 1 FROM staged_projects WHERE scan_id=? AND path_hint>=? AND path_hint<? LIMIT 1")
            let hasChildren: Bool
            do {
                defer { sqlite3_finalize(children) }
                try bind(scanID,to:children,at:1); try bind(project.path + "/",to:children,at:2); try bind(project.path + "0",to:children,at:3)
                hasChildren = try rowAvailable(children)
            }
            var observationPath = ""
            var observationID: Int64 = 0
            var latest = project.date
            while true {
                try Task.checkCancellation()
                let statement = try prepare("""
                SELECT o.path_hint,o.id,o.modified_at FROM project_activity_observations o
                WHERE o.scan_id=? AND o.path_hint>=? AND o.path_hint<?
                  AND (o.path_hint=? OR o.path_hint>=?)
                  AND (o.path_hint,o.id) > (?,?)
                ORDER BY o.path_hint,o.id LIMIT 256
                """)
                var count = 0
                do {
                    defer { sqlite3_finalize(statement) }
                    try bind(scanID,to:statement,at:1)
                    try bind(project.path,to:statement,at:2)
                    try bind(project.path + "0",to:statement,at:3)
                    try bind(project.path,to:statement,at:4)
                    try bind(project.path + "/",to:statement,at:5)
                    try bind(observationPath,to:statement,at:6)
                    try check(sqlite3_bind_int64(statement,7,observationID))
                    while try rowAvailable(statement) {
                        observationPath = String(cString:sqlite3_column_text(statement,0))
                        observationID = sqlite3_column_int64(statement,1)
                        // Flat projects aggregate directly; nested projects use only indexed
                        // ancestor equality probes, never an inverse-prefix table scan.
                        if !hasChildren {
                            latest = max(latest,sqlite3_column_double(statement,2))
                        } else if try nearestStagedProjectKey(to:observationPath,scanID:scanID) == project.key {
                            latest = max(latest,sqlite3_column_double(statement,2))
                        }
                        count += 1
                    }
                }
                await Task.yield()
                if count < 256 { break }
            }
            maxima.append((project.key, latest))
            if maxima.count == 256 {
                try saveProjectScanMaxima(maxima, scanID: scanID)
                maxima.removeAll(keepingCapacity: true)
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        try saveProjectScanMaxima(maxima, scanID: scanID)
        guard activeProjectScans.contains(scanID) else { throw SQLiteSafetyStoreError.statementFailed("Project scan was aborted") }
        try execute("BEGIN IMMEDIATE")
        do {
            let publish = try prepare("""
            INSERT INTO project_activity(identity_key,path_hint,last_activity_at,last_scan_id)
            SELECT identity_key,path_hint,last_activity_at,scan_id FROM staged_projects WHERE scan_id=?
            ON CONFLICT(identity_key) DO UPDATE SET path_hint=excluded.path_hint,last_activity_at=MAX(project_activity.last_activity_at,excluded.last_activity_at),last_scan_id=excluded.last_scan_id
            """)
            defer { sqlite3_finalize(publish) }
            try bind(scanID,to:publish,at:1); try stepDone(publish)
            let delete = try prepare("DELETE FROM project_activity WHERE (path_hint=? OR (path_hint>=? AND path_hint<?)) AND last_scan_id<>?")
            defer { sqlite3_finalize(delete) }
            try bind(root,to:delete,at:1); try bind(root + "/",to:delete,at:2); try bind(root + "0",to:delete,at:3); try bind(scanID,to:delete,at:4)
            try stepDone(delete)
            try endProjectActivityScan(scanID:scanID)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func saveProjectScanMaxima(_ maxima: [(key: String, date: Double)], scanID: String) throws {
        guard !maxima.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE staged_projects SET last_activity_at=? WHERE scan_id=? AND identity_key=?")
            defer { sqlite3_finalize(statement) }
            for maximum in maxima {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try check(sqlite3_bind_double(statement, 1, maximum.date))
                try bind(scanID, to: statement, at: 2)
                try bind(maximum.key, to: statement, at: 3)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func nearestStagedProjectKey(to path: String, scanID: String) throws -> String? {
        let statement = try prepare("SELECT identity_key FROM staged_projects WHERE scan_id=? AND path_hint=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        var ancestor = RuleScope.normalized(path)
        while true {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(scanID,to:statement,at:1); try bind(ancestor,to:statement,at:2)
            if try rowAvailable(statement) { return String(cString:sqlite3_column_text(statement,0)) }
            if ancestor == "/" { return nil }
            ancestor = (ancestor as NSString).deletingLastPathComponent
            if ancestor.isEmpty { ancestor = "/" }
        }
    }

    private func nextStagedProject(scanID: String, after: String) throws -> (key: String,path: String,date: Double)? {
        let statement = try prepare("SELECT identity_key,path_hint,last_activity_at FROM staged_projects WHERE scan_id=? AND identity_key>? ORDER BY identity_key LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(scanID,to:statement,at:1); try bind(after,to:statement,at:2)
        guard try rowAvailable(statement) else { return nil }
        return (String(cString:sqlite3_column_text(statement,0)),String(cString:sqlite3_column_text(statement,1)),sqlite3_column_double(statement,2))
    }

    private func nearestProject(to path: String) throws -> (key: String,path: String,date: Date)? {
        let statement = try prepare("SELECT identity_key,last_activity_at FROM project_activity WHERE path_hint=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        var ancestor = RuleScope.normalized(path)
        while true {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(ancestor,to:statement,at:1)
            if try rowAvailable(statement) {
                return (String(cString:sqlite3_column_text(statement,0)),ancestor,Date(timeIntervalSince1970:sqlite3_column_double(statement,1)))
            }
            if ancestor == "/" { return nil }
            ancestor = (ancestor as NSString).deletingLastPathComponent
            if ancestor.isEmpty { ancestor = "/" }
        }
    }

    public func projectActivity(for path: String) throws -> Date? {
        try nearestProject(to:path)?.date
    }

    public func recordProjectActivity(at path: String, date: Date) throws -> String? {
        guard let project = try nearestProject(to:path) else { return nil }
        guard date > project.date else { return project.path }
        let update = try prepare("UPDATE project_activity SET last_activity_at=MAX(last_activity_at,?) WHERE identity_key=?")
        defer { sqlite3_finalize(update) }
        try check(sqlite3_bind_double(update,1,date.timeIntervalSince1970))
        try bind(project.key,to:update,at:2); try stepDone(update)
        return project.path
    }

    public func removeProjectActivity(atOrBelow path: String) throws {
        let root = RuleScope.normalized(path)
        let statement = try prepare("DELETE FROM project_activity WHERE path_hint = ? OR (path_hint >= ? AND path_hint < ?)")
        defer { sqlite3_finalize(statement) }
        try bind(root, to: statement, at: 1)
        try bind(root + "/", to: statement, at: 2)
        try bind(root + "0", to: statement, at: 3)
        try stepDone(statement)
    }

    public func upcomingDeadlines(limit: Int = 50) throws -> [PersistedDeadline] {
        let statement = try prepare("SELECT payload FROM deadlines ORDER BY scheduled_at ASC, identity_key ASC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, Int64(max(0, limit))))
        var result: [PersistedDeadline] = []
        while try rowAvailable(statement) {
            result.append(try decode(PersistedDeadline.self, from: columnData(statement, at: 0)))
        }
        return result
    }

    public func nextDeadline() throws -> PersistedDeadline? {
        try upcomingDeadlines(limit: 1).first
    }

    public func beginCandidateScan(atOrBelow path: String) throws -> String {
        let scanID = UUID().uuidString
        let statement = try prepare("INSERT INTO candidate_scans VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(scanID,to:statement,at:1)
        try bind(RuleScope.normalized(path),to:statement,at:2)
        try stepDone(statement)
        return scanID
    }

    public func stageCandidates(_ candidates: [RuleCandidate], scanID: String) throws {
        guard !candidates.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO staged_candidates VALUES(?,?,?) ON CONFLICT(scan_id,identity_key) DO UPDATE SET payload=excluded.payload")
            defer { sqlite3_finalize(statement) }
            for candidate in candidates {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(scanID,to:statement,at:1)
                try bind(Self.identityKey(candidate.identity),to:statement,at:2)
                try bind(try encode(candidate),to:statement,at:3)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func candidatePage(scanID: String, afterIdentityKey: String? = nil, limit: Int = 256) throws -> PersistedCandidatePage {
        let statement = try prepare("SELECT identity_key,payload FROM staged_candidates WHERE scan_id=? AND identity_key > ? ORDER BY identity_key LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try bind(scanID,to:statement,at:1)
        try bind(afterIdentityKey ?? "",to:statement,at:2)
        let bounded = min(256,max(1,limit))
        try check(sqlite3_bind_int64(statement,3,Int64(bounded + 1)))
        var candidates: [RuleCandidate] = []
        var cursor: String?
        var more = false
        while try rowAvailable(statement) {
            if candidates.count == bounded { more = true; break }
            cursor = String(cString:sqlite3_column_text(statement,0))
            candidates.append(try decode(RuleCandidate.self,from:columnData(statement,at:1)))
        }
        return PersistedCandidatePage(candidates:candidates,nextCursor:more ? cursor : nil)
    }

    public func stageDeadlines(_ deadlines: [PersistedDeadline], scanID: String) throws {
        guard !deadlines.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO staged_deadlines VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(scan_id,identity_key) DO UPDATE SET scheduled_at=excluded.scheduled_at,path_hint=excluded.path_hint,payload=excluded.payload,rule_id=excluded.rule_id,disposition=excluded.disposition,expiry_basis=excluded.expiry_basis")
            defer { sqlite3_finalize(statement) }
            for deadline in deadlines {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(scanID,to:statement,at:1)
                try bind(Self.identityKey(deadline.identity),to:statement,at:2)
                try check(sqlite3_bind_double(statement,3,deadline.scheduledAt.timeIntervalSince1970))
                try bind(deadline.identity.pathHint,to:statement,at:4)
                try bind(try encode(deadline),to:statement,at:5)
                if deadline.explanation.customOverrideID == nil { try bind(deadline.explanation.matchedRuleID.uuidString,to:statement,at:6) }
                else { try check(sqlite3_bind_null(statement,6)) }
                try bind(deadline.explanation.disposition.rawValue,to:statement,at:7)
                try bind(deadline.explanation.expiryBasis.rawValue,to:statement,at:8)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func commitCandidateScan(scanID: String) throws {
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            let select = try prepare("SELECT path_hint FROM candidate_scans WHERE scan_id=?")
            defer { sqlite3_finalize(select) }
            try bind(scanID,to:select,at:1)
            guard try rowAvailable(select) else { throw SQLiteSafetyStoreError.statementFailed("Unknown candidate scan") }
            let root = String(cString:sqlite3_column_text(select,0))
            let delete = try prepare("DELETE FROM deadlines WHERE (path_hint=? OR (path_hint>=? AND path_hint<?)) AND identity_key NOT IN (SELECT identity_key FROM staged_deadlines WHERE scan_id=?)")
            defer { sqlite3_finalize(delete) }
            try bind(root,to:delete,at:1); try bind(root + "/",to:delete,at:2); try bind(root + "0",to:delete,at:3); try bind(scanID,to:delete,at:4)
            try stepDone(delete)
            let publish = try prepare("""
            INSERT INTO deadlines(identity_key,scheduled_at,path_hint,payload,rule_id,disposition,expiry_basis)
            SELECT identity_key,scheduled_at,path_hint,payload,rule_id,disposition,expiry_basis FROM staged_deadlines WHERE scan_id=?
            ON CONFLICT(identity_key) DO UPDATE SET scheduled_at=excluded.scheduled_at,path_hint=excluded.path_hint,payload=excluded.payload,rule_id=excluded.rule_id,disposition=excluded.disposition,expiry_basis=excluded.expiry_basis WHERE deadlines.payload<>excluded.payload
            """)
            defer { sqlite3_finalize(publish) }
            try bind(scanID,to:publish,at:1); try stepDone(publish)
            try endCandidateScan(scanID:scanID)
            try Task.checkCancellation()
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func endCandidateScan(scanID: String) throws {
        for table in ["staged_candidates","staged_deadlines","candidate_scans"] {
            let statement = try prepare("DELETE FROM \(table) WHERE scan_id=?")
            defer { sqlite3_finalize(statement) }
            try bind(scanID,to:statement,at:1); try stepDone(statement)
        }
    }

    public func reclaimedTotals() throws -> PersistedReclaimedTotals {
        let statement = try prepare("SELECT items,bytes,known_items,first_at,last_at FROM reclaimed_totals WHERE id=1")
        defer { sqlite3_finalize(statement) }
        guard try rowAvailable(statement) else { throw databaseError() }
        return PersistedReclaimedTotals(
            lifetimeItems: Int(sqlite3_column_int64(statement,0)),
            lifetimeBytes: sqlite3_column_int64(statement,1),
            itemsWithKnownSize: Int(sqlite3_column_int64(statement,2)),
            firstMovedAt: sqlite3_column_type(statement,3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement,3)),
            lastMovedAt: sqlite3_column_type(statement,4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement,4)))
    }

    public func reclaimedDay(from: Date, to: Date) throws -> PersistedReclaimedDay {
        let statement = try prepare("SELECT COALESCE(SUM(items),0),COALESCE(SUM(bytes),0) FROM reclaimed_moves WHERE occurred_at >= ? AND occurred_at < ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement,1,from.timeIntervalSince1970))
        try check(sqlite3_bind_double(statement,2,to.timeIntervalSince1970))
        guard try rowAvailable(statement) else { throw databaseError() }
        return PersistedReclaimedDay(items: Int(sqlite3_column_int64(statement,0)),bytes: sqlite3_column_int64(statement,1))
    }

    public func reclaimedSnapshot(intervals: [DateInterval]) throws -> PersistedReclaimedSnapshot {
        PersistedReclaimedSnapshot(
            totals: try reclaimedTotals(),
            days: try intervals.map { try reclaimedDay(from: $0.start, to: $0.end) }
        )
    }

    /// One actor turn keeps samples, counts, and policy coherent across a scan's atomic publication.
    public func overviewSnapshot(now: Date) throws -> PersistedOverviewSnapshot {
        let policy = try readPolicySnapshot()
        let active = try upcomingPage(ruleID: nil, disposition: .active, after: nil, limit: 100, dueThrough: nil, count: false)
        let preview = try upcomingPage(ruleID: nil, disposition: .preview, after: nil, limit: 100, dueThrough: nil, count: false)
        let summary = try deadlineSummary(now: now)
        return PersistedOverviewSnapshot(
            policy: policy,
            upcoming: active.deadlines + preview.deadlines,
            summary: summary,
            ruleCounts: try deadlineCountsByRule(now: now),
            indexedItems: summary.active + summary.preview
        )
    }

    public func upcomingDeadlinePage(ruleID: UUID? = nil, disposition: ScheduledDisposition? = nil,
        after: PersistedUpcomingCursor? = nil, limit: Int = 200, dueThrough: Date? = nil) throws -> PersistedUpcomingPage {
        try upcomingPage(ruleID: ruleID, disposition: disposition, after: after, limit: limit, dueThrough: dueThrough, count: true)
    }

    public func dueDeadlinePage(through: Date, after: PersistedUpcomingCursor? = nil, limit: Int = 256) throws -> PersistedUpcomingPage {
        try upcomingPage(ruleID: nil, disposition: nil, after: after, limit: limit, dueThrough: through, count: false)
    }

    private func upcomingPage(ruleID: UUID?, disposition: ScheduledDisposition?, after: PersistedUpcomingCursor?,
        limit: Int, dueThrough: Date?, count: Bool) throws -> PersistedUpcomingPage {
        var filters: [String] = []
        if ruleID != nil { filters.append("rule_id = ?") }
        if disposition != nil { filters.append("disposition = ?") }
        if dueThrough != nil { filters.append("scheduled_at <= ?") }
        let population = filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")
        func bindFilters(_ statement: OpaquePointer) throws -> Int32 {
            var index: Int32 = 1
            if let ruleID { try bind(ruleID.uuidString,to:statement,at:index); index += 1 }
            if let disposition { try bind(disposition.rawValue,to:statement,at:index); index += 1 }
            if let dueThrough { try check(sqlite3_bind_double(statement,index,dueThrough.timeIntervalSince1970)); index += 1 }
            return index
        }
        var total = 0
        if count {
            let statement = try prepare("SELECT COUNT(*) FROM deadlines" + population)
            defer { sqlite3_finalize(statement) }
            _ = try bindFilters(statement)
            if try rowAvailable(statement) { total = Int(sqlite3_column_int64(statement,0)) }
        }
        if after != nil { filters.append("(scheduled_at,identity_key) > (?,?)") }
        let predicate = filters.isEmpty ? "" : " WHERE " + filters.joined(separator:" AND ")
        let statement = try prepare("SELECT payload,scheduled_at,identity_key FROM deadlines" + predicate + " ORDER BY scheduled_at,identity_key LIMIT ?")
        defer { sqlite3_finalize(statement) }
        var index = try bindFilters(statement)
        if let after {
            try check(sqlite3_bind_double(statement,index,after.scheduledAt.timeIntervalSince1970)); index += 1
            try bind(after.identityKey,to:statement,at:index); index += 1
        }
        let bounded = min(256,max(1,limit))
        try check(sqlite3_bind_int64(statement,index,Int64(bounded + 1)))
        var deadlines: [PersistedDeadline] = []
        var cursor: PersistedUpcomingCursor?
        var more = false
        while try rowAvailable(statement) {
            if deadlines.count == bounded { more = true; break }
            deadlines.append(try decode(PersistedDeadline.self,from:columnData(statement,at:0)))
            cursor = PersistedUpcomingCursor(scheduledAt:Date(timeIntervalSince1970:sqlite3_column_double(statement,1)),identityKey:String(cString:sqlite3_column_text(statement,2)))
        }
        return PersistedUpcomingPage(deadlines:deadlines,nextCursor:more ? cursor : nil,totalCount:total)
    }

    public func nextScheduledTime(after: Date) throws -> Date? {
        let statement = try prepare("SELECT MIN(scheduled_at) FROM deadlines WHERE scheduled_at > ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement,1,after.timeIntervalSince1970))
        guard try rowAvailable(statement), sqlite3_column_type(statement,0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970:sqlite3_column_double(statement,0))
    }

    public func deadlineSummary(now: Date) throws -> PersistedDeadlineSummary {
        let statement = try prepare("SELECT disposition,COUNT(*),SUM(CASE WHEN scheduled_at <= ? THEN 1 ELSE 0 END) FROM deadlines GROUP BY disposition")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement,1,now.addingTimeInterval(86_400).timeIntervalSince1970))
        var active = 0, preview = 0, soon = 0
        while try rowAvailable(statement) {
            if String(cString:sqlite3_column_text(statement,0)) == ScheduledDisposition.active.rawValue {
                active = Int(sqlite3_column_int64(statement,1)); soon = Int(sqlite3_column_int64(statement,2))
            } else { preview += Int(sqlite3_column_int64(statement,1)) }
        }
        return PersistedDeadlineSummary(active:active,preview:preview,activeSoon:soon)
    }

    /// Per-rule counts of scheduled candidates, read from the persisted deadline index only.
    public func deadlineCountsByRule(now: Date) throws -> [UUID: (matches: Int, due: Int)] {
        let statement = try prepare("""
        SELECT rule_id, COUNT(*), SUM(CASE WHEN scheduled_at <= ? THEN 1 ELSE 0 END)
        FROM deadlines WHERE rule_id IS NOT NULL GROUP BY rule_id
        """)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, now.timeIntervalSince1970))
        var result: [UUID: (matches: Int, due: Int)] = [:]
        while try rowAvailable(statement) {
            guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) else { continue }
            result[id] = (Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 2)))
        }
        return result
    }

    public func indexedDeadlineCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM deadlines")
        defer { sqlite3_finalize(statement) }
        guard try rowAvailable(statement) else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func databaseSizeBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func deadlinePage(atOrBelow path: String, afterIdentityKey cursor: String? = nil, limit: Int = 256, expiryBasis: ExpiryBasis? = nil) throws -> PersistedDeadlinePage {
        let root = RuleScope.normalized(path)
        let basisFilter = expiryBasis == nil ? "" : " AND expiry_basis=?"
        let statement = try prepare("SELECT identity_key,payload FROM deadlines WHERE (path_hint=? OR (path_hint>=? AND path_hint<?)) AND identity_key>?" + basisFilter + " ORDER BY identity_key LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try bind(root,to:statement,at:1); try bind(root + "/",to:statement,at:2); try bind(root + "0",to:statement,at:3)
        try bind(cursor ?? "",to:statement,at:4)
        if let expiryBasis { try bind(expiryBasis.rawValue,to:statement,at:5) }
        let bounded = min(256,max(1,limit))
        try check(sqlite3_bind_int64(statement,expiryBasis == nil ? 5 : 6,Int64(bounded)))
        var rows: [(String,PersistedDeadline)] = []
        while try rowAvailable(statement) {
            rows.append((String(cString:sqlite3_column_text(statement,0)),try decode(PersistedDeadline.self,from:columnData(statement,at:1))))
        }
        return PersistedDeadlinePage(deadlines:rows.map(\.1),nextCursor:rows.count == bounded ? rows.last?.0 : nil)
    }

    private func loadPayloads<Value: Decodable>(table: String, as type: Value.Type) throws -> [Value] {
        guard table == "rules" || table == "item_overrides" || table == "managed_roots" else {
            throw SQLiteSafetyStoreError.statementFailed("invalid policy table")
        }
        let statement = try prepare("SELECT payload FROM \(table) ORDER BY position ASC, id ASC")
        defer { sqlite3_finalize(statement) }
        var result: [Value] = []
        while try rowAvailable(statement) {
            result.append(try decode(type, from: columnData(statement, at: 0)))
        }
        return result
    }

    private func insertPayload<Value: Encodable>(table: String, id: String, position: Int, value: Value) throws {
        guard table == "rules" || table == "item_overrides" || table == "managed_roots" else {
            throw SQLiteSafetyStoreError.statementFailed("invalid policy table")
        }
        let statement = try prepare("INSERT INTO \(table)(id, position, payload) VALUES(?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try check(sqlite3_bind_int64(statement, 2, Int64(position)))
        try bind(try encode(value), to: statement, at: 3)
        try stepDone(statement)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw SQLiteSafetyStoreError.encodingFailed(String(describing: error)) }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try decoder.decode(type, from: data) }
        catch { throw SQLiteSafetyStoreError.encodingFailed(String(describing: error)) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw databaseError() }
        return statement
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database!, sql)
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw SQLiteSafetyStoreError.statementFailed(reason)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
        try check(result)
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        try check(result)
    }

    private func columnData(_ statement: OpaquePointer, at index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw databaseError() }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func databaseError() -> SQLiteSafetyStoreError {
        .statementFailed(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite connection is closed")
    }
    private func rowAvailable(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }


    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func identityKey(_ identity: FilesystemIdentity) -> String {
        let resource = identity.resourceIdentifier.map { String(format: "%02x", $0) }.joined()
        let key = "\(identity.volumeIdentifier.uuidString):\(resource)"
        // Device-number volume ids are only meaningful until the next restart/remount; the prefix lets startup purge them.
        return identity.isPersistent ? key : "np:" + key
    }

    private static func migrate(_ database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let sql = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY NOT NULL, applied_at REAL NOT NULL);
        PRAGMA user_version;
        """
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw SQLiteSafetyStoreError.statementFailed(reason)
        }

        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else {
            throw SQLiteSafetyStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        let step = sqlite3_step(versionStatement)
        var version = step == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
        sqlite3_finalize(versionStatement)

        if version < 1 {
            let migration = """
            BEGIN IMMEDIATE;
            CREATE TABLE rules(id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE item_overrides(id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE settings(id INTEGER PRIMARY KEY CHECK(id = 1), globally_paused INTEGER NOT NULL DEFAULT 0 CHECK(globally_paused IN (0, 1)));
            INSERT INTO settings(id, globally_paused) VALUES(1, 0);
            CREATE TABLE deadlines(identity_key TEXT PRIMARY KEY NOT NULL, scheduled_at REAL NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX deadline_due_idx ON deadlines(scheduled_at, identity_key);
            CREATE TABLE audit_events(id TEXT PRIMARY KEY NOT NULL, occurred_at REAL NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX audit_chronology_idx ON audit_events(occurred_at DESC, id DESC);
            INSERT INTO schema_migrations(version, applied_at) VALUES(1, strftime('%s', 'now'));
            PRAGMA user_version = 1;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
            version = 1
        }

        if version < 2 {
            let migration = """
            BEGIN IMMEDIATE;
            CREATE TABLE managed_roots(id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX managed_root_order_idx ON managed_roots(position, id);
            INSERT INTO schema_migrations(version, applied_at) VALUES(2, strftime('%s', 'now'));
            PRAGMA user_version = 2;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 3 {
            let migration = """
            BEGIN IMMEDIATE;
            ALTER TABLE deadlines ADD COLUMN path_hint TEXT NOT NULL DEFAULT '';
            UPDATE deadlines SET path_hint = json_extract(CAST(payload AS TEXT), '$.identity.pathHint') WHERE path_hint = '';
            CREATE INDEX deadline_path_idx ON deadlines(path_hint);
            INSERT INTO schema_migrations(version, applied_at) VALUES(3, strftime('%s', 'now'));
            PRAGMA user_version = 3;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 4 {
            let migration = """
            BEGIN IMMEDIATE;
            CREATE TABLE observed_activity(
                identity_key TEXT PRIMARY KEY NOT NULL,
                path_hint TEXT NOT NULL,
                first_observed_at REAL NOT NULL,
                last_observed_at REAL NOT NULL
            );
            CREATE INDEX observed_activity_path_idx ON observed_activity(path_hint);
            INSERT INTO schema_migrations(version, applied_at) VALUES(4, strftime('%s', 'now'));
            PRAGMA user_version = 4;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 5 {
            let migration = """
            BEGIN IMMEDIATE;
            CREATE TABLE event_cursors(root_id TEXT PRIMARY KEY NOT NULL, event_id TEXT NOT NULL);
            INSERT INTO schema_migrations(version, applied_at) VALUES(5, strftime('%s', 'now'));
            PRAGMA user_version = 5;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 6 {
            let migration = """
            BEGIN IMMEDIATE;
            CREATE TABLE project_activity(
                identity_key TEXT PRIMARY KEY NOT NULL,
                path_hint TEXT NOT NULL,
                last_activity_at REAL NOT NULL,
                last_scan_id TEXT NOT NULL
            );
            CREATE INDEX project_activity_path_idx ON project_activity(path_hint);
            CREATE TABLE project_activity_observations(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scan_id TEXT NOT NULL,
                path_hint TEXT NOT NULL,
                modified_at REAL NOT NULL
            );
            CREATE INDEX project_activity_observation_scan_idx ON project_activity_observations(scan_id, id);
            INSERT INTO schema_migrations(version, applied_at) VALUES(6, strftime('%s', 'now'));
            PRAGMA user_version = 6;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 7 {
            let migration = """
            BEGIN IMMEDIATE;
            ALTER TABLE settings ADD COLUMN pause_until REAL;
            ALTER TABLE settings ADD COLUMN default_grace_seconds REAL NOT NULL DEFAULT 0;
            ALTER TABLE settings ADD COLUMN protect_hidden_files INTEGER NOT NULL DEFAULT 0 CHECK(protect_hidden_files IN (0, 1));
            ALTER TABLE settings ADD COLUMN activity_retention_days INTEGER NOT NULL DEFAULT 0 CHECK(activity_retention_days >= 0);
            INSERT INTO schema_migrations(version, applied_at) VALUES(7, strftime('%s', 'now'));
            PRAGMA user_version = 7;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 8 {
            let migration = """
            BEGIN IMMEDIATE;
            ALTER TABLE settings ADD COLUMN policy_revision INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE deadlines ADD COLUMN rule_id TEXT;
            UPDATE deadlines SET rule_id = json_extract(CAST(payload AS TEXT), '$.explanation.matchedRuleID')
                WHERE json_extract(CAST(payload AS TEXT), '$.explanation.customOverrideID') IS NULL;
            CREATE INDEX deadline_rule_idx ON deadlines(rule_id);
            INSERT INTO schema_migrations(version, applied_at) VALUES(8, strftime('%s', 'now'));
            PRAGMA user_version = 8;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 9 {
            let migration = """
            BEGIN IMMEDIATE;
            CREATE INDEX audit_moved_ledger_idx ON audit_events(occurred_at ASC, id ASC) WHERE kind = 'movedToTrash';
            INSERT INTO schema_migrations(version, applied_at) VALUES(9, strftime('%s', 'now'));
            PRAGMA user_version = 9;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
        if version < 10 {
            let migration = """
            BEGIN IMMEDIATE;
            ALTER TABLE deadlines ADD COLUMN disposition TEXT NOT NULL DEFAULT 'preview';
            ALTER TABLE deadlines ADD COLUMN expiry_basis TEXT NOT NULL DEFAULT '';
            UPDATE deadlines SET disposition=json_extract(CAST(payload AS TEXT),'$.explanation.disposition'),
                expiry_basis=json_extract(CAST(payload AS TEXT),'$.explanation.expiryBasis');
            CREATE INDEX deadline_disposition_due_idx ON deadlines(disposition,scheduled_at,identity_key);
            CREATE INDEX deadline_rule_due_idx ON deadlines(rule_id,scheduled_at,identity_key);
            CREATE INDEX deadline_basis_path_idx ON deadlines(expiry_basis,path_hint,identity_key);
            CREATE TABLE candidate_scans(scan_id TEXT PRIMARY KEY NOT NULL, path_hint TEXT NOT NULL);
            CREATE TABLE staged_candidates(scan_id TEXT NOT NULL, identity_key TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(scan_id,identity_key));
            CREATE TABLE staged_deadlines(scan_id TEXT NOT NULL, identity_key TEXT NOT NULL, scheduled_at REAL NOT NULL, path_hint TEXT NOT NULL, payload BLOB NOT NULL, rule_id TEXT, disposition TEXT NOT NULL, expiry_basis TEXT NOT NULL, PRIMARY KEY(scan_id,identity_key));
            CREATE TABLE staged_projects(scan_id TEXT NOT NULL, identity_key TEXT NOT NULL, path_hint TEXT NOT NULL, last_activity_at REAL NOT NULL, PRIMARY KEY(scan_id,identity_key));
            CREATE INDEX staged_project_path_idx ON staged_projects(scan_id,path_hint);
            CREATE INDEX project_observation_path_idx ON project_activity_observations(scan_id,path_hint,modified_at);
            CREATE INDEX project_observation_order_idx ON project_activity_observations(scan_id,path_hint,id);
            CREATE TABLE reclaimed_moves(id TEXT PRIMARY KEY NOT NULL, occurred_at REAL NOT NULL, items INTEGER NOT NULL, bytes INTEGER NOT NULL, known_items INTEGER NOT NULL);
            CREATE INDEX reclaimed_moves_time_idx ON reclaimed_moves(occurred_at,items,bytes);
            CREATE TABLE reclaimed_totals(id INTEGER PRIMARY KEY CHECK(id=1), items INTEGER NOT NULL, bytes INTEGER NOT NULL, known_items INTEGER NOT NULL, first_at REAL, last_at REAL);
            INSERT INTO reclaimed_moves
                SELECT id,occurred_at,MAX(1,COALESCE(json_extract(CAST(payload AS TEXT),'$.itemCount'),1)),
                    MAX(0,COALESCE(json_extract(CAST(payload AS TEXT),'$.bytes'),0)),
                    CASE WHEN json_extract(CAST(payload AS TEXT),'$.bytes') IS NOT NULL
                        THEN MAX(1,COALESCE(json_extract(CAST(payload AS TEXT),'$.itemCount'),1)) ELSE 0 END
                FROM audit_events WHERE kind='movedToTrash';
            INSERT INTO reclaimed_totals SELECT 1,COALESCE(SUM(items),0),COALESCE(SUM(bytes),0),COALESCE(SUM(known_items),0),MIN(occurred_at),MAX(occurred_at) FROM reclaimed_moves;
            CREATE TRIGGER reclaimed_move_insert AFTER INSERT ON reclaimed_moves BEGIN
                UPDATE reclaimed_totals SET items=items+NEW.items,bytes=bytes+NEW.bytes,known_items=known_items+NEW.known_items,
                    first_at=CASE WHEN first_at IS NULL THEN NEW.occurred_at ELSE MIN(first_at,NEW.occurred_at) END,
                    last_at=CASE WHEN last_at IS NULL THEN NEW.occurred_at ELSE MAX(last_at,NEW.occurred_at) END WHERE id=1;
            END;
            INSERT INTO schema_migrations(version,applied_at) VALUES(10,strftime('%s','now'));
            CREATE TRIGGER audit_reclaimed_insert AFTER INSERT ON audit_events WHEN NEW.kind='movedToTrash' BEGIN
                INSERT INTO reclaimed_moves VALUES(NEW.id,NEW.occurred_at,
                    MAX(1,COALESCE(json_extract(CAST(NEW.payload AS TEXT),'$.itemCount'),1)),
                    MAX(0,COALESCE(json_extract(CAST(NEW.payload AS TEXT),'$.bytes'),0)),
                    CASE WHEN json_extract(CAST(NEW.payload AS TEXT),'$.bytes') IS NOT NULL
                        THEN MAX(1,COALESCE(json_extract(CAST(NEW.payload AS TEXT),'$.itemCount'),1)) ELSE 0 END);
            END;
            PRAGMA user_version=10;
            COMMIT;
            """
            do { try Self.execute(database, migration) }
            catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        }
}
}
