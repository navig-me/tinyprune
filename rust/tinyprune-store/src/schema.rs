use crate::{sql, Result};
use rusqlite::Connection;
pub const VERSION: i64 = 8;
const V1: &str = "
CREATE TABLE rules(id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL);
CREATE TABLE overrides(id TEXT PRIMARY KEY, position INTEGER NOT NULL, identity_key TEXT, path_hint TEXT NOT NULL, payload TEXT NOT NULL);
CREATE INDEX override_identity ON overrides(identity_key);
CREATE TABLE roots(path TEXT PRIMARY KEY, position INTEGER NOT NULL);
CREATE TABLE settings(id INTEGER PRIMARY KEY CHECK(id=1), paused INTEGER NOT NULL DEFAULT 0 CHECK(paused IN(0,1)), hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN(0,1)), grace REAL NOT NULL DEFAULT 0, windows INTEGER NOT NULL DEFAULT 0 CHECK(windows IN(0,1)));
INSERT INTO settings(id) VALUES(1);
CREATE TABLE observations(identity_key TEXT PRIMARY KEY, path_hint TEXT NOT NULL, identity TEXT NOT NULL, first REAL NOT NULL, last REAL NOT NULL);
CREATE INDEX observation_path ON observations(path_hint);
CREATE TABLE projects(identity_key TEXT PRIMARY KEY, path_hint TEXT NOT NULL, identity TEXT NOT NULL, activity REAL NOT NULL);
CREATE TABLE deadlines(identity_key TEXT PRIMARY KEY, root TEXT NOT NULL REFERENCES roots(path) ON DELETE CASCADE, scheduled_at REAL NOT NULL, payload TEXT NOT NULL);
CREATE INDEX deadline_order ON deadlines(scheduled_at,identity_key);
CREATE TABLE candidates(identity_key TEXT PRIMARY KEY, root TEXT NOT NULL REFERENCES roots(path) ON DELETE CASCADE, payload TEXT NOT NULL);
CREATE TABLE audit(id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at REAL NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL);
CREATE INDEX audit_order ON audit(occurred_at,id);
CREATE TABLE attempts(identity_key TEXT PRIMARY KEY, identity TEXT NOT NULL, audit_id INTEGER NOT NULL REFERENCES audit(id));
";
const V2: &str = "
CREATE TABLE reclaim(audit_id INTEGER PRIMARY KEY REFERENCES audit(id), occurred_at REAL NOT NULL, items INTEGER NOT NULL CHECK(items>0), bytes INTEGER NOT NULL CHECK(bytes>=0), known_items INTEGER NOT NULL);
CREATE INDEX reclaim_time ON reclaim(occurred_at);
INSERT INTO reclaim SELECT id,occurred_at,MAX(1,COALESCE(json_extract(payload,'$.items'),1)),MAX(0,COALESCE(json_extract(payload,'$.bytes'),0)),CASE WHEN json_extract(payload,'$.bytes') IS NULL THEN 0 ELSE MAX(1,COALESCE(json_extract(payload,'$.items'),1)) END FROM audit WHERE kind='movedToTrash';
";
const V3: &str = "
ALTER TABLE settings ADD COLUMN revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0);
ALTER TABLE settings ADD COLUMN paused_until REAL;
ALTER TABLE settings ADD COLUMN retention_days INTEGER NOT NULL DEFAULT 0 CHECK(retention_days>=0);
";
const V4: &str = "
CREATE INDEX decision_identity ON audit(json_extract(payload,'$.item.volumeIdentifier') COLLATE NOCASE,json_extract(payload,'$.item.resourceIdentifier') COLLATE NOCASE,id DESC) WHERE kind IN ('previewMatch','schedulingDecision');
ALTER TABLE reclaim RENAME TO reclaim_v3;
CREATE TABLE reclaim(audit_id INTEGER PRIMARY KEY, occurred_at REAL NOT NULL, items INTEGER NOT NULL CHECK(items>0), bytes INTEGER NOT NULL CHECK(bytes>=0), known_items INTEGER NOT NULL);
INSERT INTO reclaim SELECT * FROM reclaim_v3;
DROP TABLE reclaim_v3;
CREATE INDEX reclaim_time ON reclaim(occurred_at);
";
const V5: &str = "
ALTER TABLE candidates ADD COLUMN path_hint TEXT NOT NULL DEFAULT '';
UPDATE candidates SET path_hint=COALESCE(json_extract(payload,'$.identity.path'),'');
CREATE INDEX candidate_path ON candidates(path_hint,identity_key);
CREATE INDEX candidate_root ON candidates(root,identity_key);
CREATE INDEX deadline_root ON deadlines(root);
CREATE TABLE current_decisions(identity_key TEXT PRIMARY KEY, root TEXT NOT NULL REFERENCES roots(path) ON DELETE CASCADE, scheduled_at REAL, rule_id TEXT, preview INTEGER NOT NULL CHECK(preview IN(0,1)), payload TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX decisions_due ON current_decisions(scheduled_at,identity_key) WHERE scheduled_at IS NOT NULL;
CREATE INDEX decisions_rule ON current_decisions(rule_id,scheduled_at,identity_key) WHERE scheduled_at IS NOT NULL;
CREATE INDEX decisions_preview ON current_decisions(preview,scheduled_at,identity_key) WHERE scheduled_at IS NOT NULL;
CREATE INDEX decisions_root ON current_decisions(root);
CREATE TRIGGER candidate_decision_cleanup AFTER DELETE ON candidates BEGIN DELETE FROM current_decisions WHERE identity_key=OLD.identity_key; END;
CREATE TRIGGER candidate_decision_root AFTER UPDATE OF root ON candidates BEGIN UPDATE current_decisions SET root=NEW.root WHERE identity_key=NEW.identity_key; END;
";
const MIGRATIONS: [(i64, &str); 8] = [
    (1, V1),
    (2, V2),
    (3, V3),
    (4, V4),
    (5, V5),
    (6, V6),
    (7, V7),
    (8, V8),
];
const V6: &str = "
DELETE FROM current_decisions WHERE identity_key NOT IN (SELECT identity_key FROM candidates);
CREATE TRIGGER decision_requires_candidate BEFORE INSERT ON current_decisions WHEN NOT EXISTS(SELECT 1 FROM candidates WHERE identity_key=NEW.identity_key) BEGIN SELECT RAISE(ABORT,'decision without candidate'); END;
";
// `path_key` is the flavor-specific comparison key of `path_hint` (filled by the store, which re-keys rows when the
// flavor differs from `key_meta`), so subtree operations are index range scans instead of full-table sweeps.
const V7: &str = "
ALTER TABLE candidates ADD COLUMN path_key TEXT NOT NULL DEFAULT '';
CREATE INDEX candidate_key ON candidates(path_key);
ALTER TABLE observations ADD COLUMN path_key TEXT NOT NULL DEFAULT '';
CREATE INDEX observation_key ON observations(path_key);
CREATE TABLE key_meta(id INTEGER PRIMARY KEY CHECK(id=1), flavor INTEGER NOT NULL);
";
// Path filtering uses normalized path_key range indexes since v7; no query filters/orders by
// path_hint. Keep the root/order/filter indexes, which serve distinct queries and FK cleanup.
const V8: &str = "
DROP INDEX candidate_path;
DROP INDEX observation_path;
CREATE TRIGGER decision_archive BEFORE DELETE ON current_decisions BEGIN
INSERT INTO audit(occurred_at,kind,payload) VALUES(OLD.updated_at,CASE WHEN OLD.preview=1 THEN 'previewMatch' ELSE 'schedulingDecision' END,OLD.payload);
END;
";
pub(crate) fn migrate(c: &mut Connection) -> Result<()> {
    let version: i64 = sql(c.query_row("PRAGMA user_version", [], |r| r.get(0)))?;
    if version > VERSION {
        return Err(format!(
            "Database schema {version} is newer than supported {VERSION}"
        ));
    }
    for (number, migration) in MIGRATIONS {
        if version < number {
            let tx = sql(c.transaction())?;
            sql(tx.execute_batch(migration))?;
            sql(tx.pragma_update(None, "user_version", number))?;
            sql(tx.commit())?;
        }
    }
    Ok(())
}
#[cfg(test)]
pub(crate) fn at_version(c: &Connection, version: i64) {
    for (number, migration) in MIGRATIONS {
        if number <= version {
            c.execute_batch(migration).unwrap();
        }
    }
    c.pragma_update(None, "user_version", version).unwrap();
}
#[cfg(test)]
pub(crate) fn previous(c: &Connection) {
    at_version(c, VERSION - 1);
}
