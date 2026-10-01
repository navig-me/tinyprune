import CSQLite
import Foundation
import TinyPruneDomain
import TinyPruneEngine

public struct PersistedDeadline: Hashable, Codable, Sendable {
    public let identity: FilesystemIdentity
    public let scheduledAt: Date
    public let explanation: CandidateExplanation
    public init(identity: FilesystemIdentity, scheduledAt: Date, explanation: CandidateExplanation) {
        self.identity = identity
        self.scheduledAt = scheduledAt
        self.explanation = explanation
    }
}

public enum SQLiteSafetyStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case encodingFailed(String)
}

public actor SQLiteSafetyStore: PolicySnapshotProviding, TrashAuditRecording {
    public let databaseURL: URL
    nonisolated(unsafe) private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
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
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func loadSnapshot() async throws -> PolicySnapshot {
        let rules = try loadPayloads(table: "rules", as: LifetimeRule.self)
        let overrides = try loadPayloads(table: "item_overrides", as: ItemPolicyOverride.self)
        let managedRoots = try loadPayloads(table: "managed_roots", as: ManagedRoot.self)
        let statement = try prepare("SELECT globally_paused FROM settings WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteSafetyStoreError.statementFailed("global pause setting is missing")
        }
        return PolicySnapshot(rules: rules, overrides: overrides, managedRoots: managedRoots, globallyPaused: sqlite3_column_int(statement, 0) != 0)
    }

    public func replaceSnapshot(_ snapshot: PolicySnapshot) throws {
        try execute("BEGIN IMMEDIATE")
        do {
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
            let statement = try prepare("UPDATE settings SET globally_paused = ? WHERE id = 1")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_int(statement, 1, snapshot.globallyPaused ? 1 : 0))
            try stepDone(statement)
            try insertAuditEvent(TrashAuditEvent(
                occurredAt: Date(),
                kind: .policyReplaced,
                detail: "rules=\(snapshot.rules.count); overrides=\(snapshot.overrides.count); roots=\(snapshot.managedRoots.count); globallyPaused=\(snapshot.globallyPaused)"
            ))
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

    public func saveDeadline(_ deadline: PersistedDeadline) throws {
        let statement = try prepare("INSERT INTO deadlines(identity_key, scheduled_at, payload) VALUES(?, ?, ?) ON CONFLICT(identity_key) DO UPDATE SET scheduled_at=excluded.scheduled_at, payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(deadline.identity), to: statement, at: 1)
        try check(sqlite3_bind_double(statement, 2, deadline.scheduledAt.timeIntervalSince1970))
        try bind(try encode(deadline), to: statement, at: 3)
        try stepDone(statement)
    }

    public func removeDeadline(for identity: FilesystemIdentity) throws {
        let statement = try prepare("DELETE FROM deadlines WHERE identity_key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Self.identityKey(identity), to: statement, at: 1)
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
        return "\(identity.volumeIdentifier.uuidString):\(resource)"
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
}
}
