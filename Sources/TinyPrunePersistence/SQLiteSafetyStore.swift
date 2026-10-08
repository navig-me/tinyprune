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
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func loadSnapshot() async throws -> PolicySnapshot {
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
        let statement = try prepare("DELETE FROM audit_events WHERE occurred_at < ? AND id <> ?")
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
        try persistDeadline(deadline)
    }

    public func saveDeadlines(_ deadlines: [PersistedDeadline]) throws {
        guard !deadlines.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for deadline in deadlines { try persistDeadline(deadline) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func persistDeadline(_ deadline: PersistedDeadline) throws {
        let statement = try prepare("""
        INSERT INTO deadlines(identity_key, scheduled_at, path_hint, payload, rule_id) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(identity_key) DO UPDATE SET scheduled_at=excluded.scheduled_at, path_hint=excluded.path_hint, payload=excluded.payload, rule_id=excluded.rule_id
        """)
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(deadline.identity), to: statement, at: 1)
        try check(sqlite3_bind_double(statement, 2, deadline.scheduledAt.timeIntervalSince1970))
        try bind(deadline.identity.pathHint, to: statement, at: 3)
        try bind(try encode(deadline), to: statement, at: 4)
        if deadline.explanation.customOverrideID == nil {
            try bind(deadline.explanation.matchedRuleID.uuidString, to: statement, at: 5)
        } else {
            try check(sqlite3_bind_null(statement, 5))
        }
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

    public func observedActivity(for identity: FilesystemIdentity) throws -> PersistedObservedActivity? {
        let statement = try prepare("SELECT first_observed_at, last_observed_at FROM observed_activity WHERE identity_key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(identity), to: statement, at: 1)
        guard try rowAvailable(statement) else { return nil }
        return PersistedObservedActivity(
            identity: identity,
            firstObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        )
    }


    public func recordObservedActivity(identity: FilesystemIdentity, at date: Date) throws {
        let statement = try prepare("""
        INSERT INTO observed_activity(identity_key, path_hint, first_observed_at, last_observed_at) VALUES(?, ?, ?, ?)
        ON CONFLICT(identity_key) DO UPDATE SET path_hint=excluded.path_hint, last_observed_at=excluded.last_observed_at
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

    /// Starts a scan. Observation rows of scans that are no longer running (crashed or abandoned) are dropped;
    /// observations of scans still in flight (other roots scanning concurrently) are left alone.
    public func beginProjectActivityScan() throws -> String {
        let listing = try prepare("SELECT DISTINCT scan_id FROM project_activity_observations")
        var orphans: [String] = []
        do {
            defer { sqlite3_finalize(listing) }
            while try rowAvailable(listing) {
                let id = String(cString: sqlite3_column_text(listing, 0))
                if !activeProjectScans.contains(id) { orphans.append(id) }
            }
        }
        for orphan in orphans {
            let delete = try prepare("DELETE FROM project_activity_observations WHERE scan_id = ?")
            defer { sqlite3_finalize(delete) }
            try bind(orphan, to: delete, at: 1)
            try stepDone(delete)
        }
        let scanID = UUID().uuidString
        activeProjectScans.insert(scanID)
        return scanID
    }

    /// Releases a scan that ended without `finishProjectActivityScan` (cancelled or failed).
    public func endProjectActivityScan(scanID: String) throws {
        activeProjectScans.remove(scanID)
        let delete = try prepare("DELETE FROM project_activity_observations WHERE scan_id = ?")
        defer { sqlite3_finalize(delete) }
        try bind(scanID, to: delete, at: 1)
        try stepDone(delete)
    }

    public func recordProjectActivities(_ projects: [PersistedProjectActivity], scanID: String) throws {
        guard !projects.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
            INSERT INTO project_activity(identity_key, path_hint, last_activity_at, last_scan_id)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(identity_key) DO UPDATE SET
                path_hint=excluded.path_hint,
                last_activity_at=MAX(project_activity.last_activity_at, excluded.last_activity_at),
                last_scan_id=excluded.last_scan_id
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

    public func finishProjectActivityScan(scanID: String, atOrBelow path: String) throws {
        let root = RuleScope.normalized(path)
        try execute("BEGIN IMMEDIATE")
        do {
            let observations = try prepare("SELECT id, path_hint, modified_at FROM project_activity_observations WHERE scan_id = ? AND id > ? ORDER BY id LIMIT 256")
            let nearestProject = try prepare("""
            SELECT identity_key FROM project_activity
            WHERE path_hint = ? OR substr(?, 1, length(path_hint) + 1) = path_hint || '/'
            ORDER BY length(path_hint) DESC LIMIT 1
            """)
            let updateProject = try prepare("UPDATE project_activity SET last_activity_at=MAX(last_activity_at, ?) WHERE identity_key = ?")
            defer {
                sqlite3_finalize(observations)
                sqlite3_finalize(nearestProject)
                sqlite3_finalize(updateProject)
            }
            var cursor: Int64 = 0
            while true {
                sqlite3_reset(observations)
                sqlite3_clear_bindings(observations)
                try bind(scanID, to: observations, at: 1)
                try check(sqlite3_bind_int64(observations, 2, cursor))
                var batch: [(id: Int64, path: String, date: Date)] = []
                while try rowAvailable(observations) {
                    let id = sqlite3_column_int64(observations, 0)
                    batch.append((
                        id,
                        String(cString: sqlite3_column_text(observations, 1)),
                        Date(timeIntervalSince1970: sqlite3_column_double(observations, 2))
                    ))
                }
                guard !batch.isEmpty else { break }
                for observation in batch {
                    cursor = observation.id
                    sqlite3_reset(nearestProject)
                    sqlite3_clear_bindings(nearestProject)
                    try bind(observation.path, to: nearestProject, at: 1)
                    try bind(observation.path, to: nearestProject, at: 2)
                    guard try rowAvailable(nearestProject) else { continue }
                    let identityKey = String(cString: sqlite3_column_text(nearestProject, 0))
                    sqlite3_reset(updateProject)
                    sqlite3_clear_bindings(updateProject)
                    try check(sqlite3_bind_double(updateProject, 1, observation.date.timeIntervalSince1970))
                    try bind(identityKey, to: updateProject, at: 2)
                    try stepDone(updateProject)
                }
            }

            let deleteStale = try prepare("""
            DELETE FROM project_activity
            WHERE (path_hint = ? OR (path_hint >= ? AND path_hint < ?))
              AND last_scan_id <> ?
            """)
            defer { sqlite3_finalize(deleteStale) }
            try bind(root, to: deleteStale, at: 1)
            try bind(root + "/", to: deleteStale, at: 2)
            try bind(root + "0", to: deleteStale, at: 3)
            try bind(scanID, to: deleteStale, at: 4)
            try stepDone(deleteStale)

            let clearObservations = try prepare("DELETE FROM project_activity_observations WHERE scan_id = ?")
            defer { sqlite3_finalize(clearObservations) }
            try bind(scanID, to: clearObservations, at: 1)
            try stepDone(clearObservations)
            try execute("COMMIT")
            activeProjectScans.remove(scanID)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func projectActivity(for path: String) throws -> Date? {
        let statement = try prepare("""
        SELECT last_activity_at FROM project_activity
        WHERE path_hint = ? OR substr(?, 1, length(path_hint) + 1) = path_hint || '/'
        ORDER BY length(path_hint) DESC LIMIT 1
        """)
        defer { sqlite3_finalize(statement) }
        let normalizedPath = RuleScope.normalized(path)
        try bind(normalizedPath, to: statement, at: 1)
        try bind(normalizedPath, to: statement, at: 2)
        guard try rowAvailable(statement) else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func recordProjectActivity(at path: String, date: Date) throws -> String? {
        do {
            let statement = try prepare("""
            SELECT identity_key, path_hint FROM project_activity
            WHERE path_hint = ? OR substr(?, 1, length(path_hint) + 1) = path_hint || '/'
            ORDER BY length(path_hint) DESC LIMIT 1
            """)
            defer { sqlite3_finalize(statement) }
            let normalizedPath = RuleScope.normalized(path)
            try bind(normalizedPath, to: statement, at: 1)
            try bind(normalizedPath, to: statement, at: 2)
            guard try rowAvailable(statement) else { return nil }
            let identityKey = String(cString: sqlite3_column_text(statement, 0))
            let projectPath = String(cString: sqlite3_column_text(statement, 1))
            sqlite3_reset(statement)
            let update = try prepare("UPDATE project_activity SET last_activity_at=MAX(last_activity_at, ?) WHERE identity_key = ?")
            defer { sqlite3_finalize(update) }
            try check(sqlite3_bind_double(update, 1, date.timeIntervalSince1970))
            try bind(identityKey, to: update, at: 2)
            try stepDone(update)
            return projectPath
        } catch {
            throw SQLiteSafetyStoreError.statementFailed("record project activity for \(path): \(error)")
        }
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

    public func deadlinePage(atOrBelow path: String, afterIdentityKey cursor: String? = nil, limit: Int = 256) throws -> PersistedDeadlinePage {
        let root = RuleScope.normalized(path)
        let statement: OpaquePointer
        if cursor == nil {
            statement = try prepare("""
            SELECT identity_key, payload FROM deadlines
            WHERE path_hint = ? OR (path_hint >= ? AND path_hint < ?)
            ORDER BY identity_key LIMIT ?
            """)
        } else {
            statement = try prepare("""
            SELECT identity_key, payload FROM deadlines
            WHERE (path_hint = ? OR (path_hint >= ? AND path_hint < ?))
              AND identity_key > ?
            ORDER BY identity_key LIMIT ?
            """)
        }
        defer { sqlite3_finalize(statement) }
        try bind(root, to: statement, at: 1)
        try bind(root + "/", to: statement, at: 2)
        try bind(root + "0", to: statement, at: 3)
        let pageLimit = min(256, max(1, limit))
        if let cursor {
            try bind(cursor, to: statement, at: 4)
            try check(sqlite3_bind_int64(statement, 5, Int64(pageLimit)))
        } else {
            try check(sqlite3_bind_int64(statement, 4, Int64(pageLimit)))
        }
        var rows: [(String, PersistedDeadline)] = []
        while try rowAvailable(statement) {
            rows.append((
                String(cString: sqlite3_column_text(statement, 0)),
                try decode(PersistedDeadline.self, from: columnData(statement, at: 1))
            ))
        }
        return PersistedDeadlinePage(
            deadlines: rows.map(\.1),
            nextCursor: rows.count == pageLimit ? rows.last?.0 : nil
        )
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
}
}
