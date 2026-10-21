//! Diagnostic SQLite cost matrix; never changes Store's FULL durability policy.
use rusqlite::{params, Connection, TransactionBehavior};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    time::Instant,
};

#[test]
#[ignore = "100k file-backed SQLite durability/index/payload cost matrix"]
fn raw_sqlite_100k_matrix() {
    const ROWS: usize = 100_000;
    const BATCH: usize = 4_096;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "tinyprune-sqlite-matrix-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let mut report = String::from("\n### Raw SQLite 100k decision + audit matrix\n\nSynthetic metadata only; 25 transactions of up to 4,096 changed rows (final batch: 1,696). Preparation/serialization excluded; SQL includes statement stepping and index maintenance; commit includes SQLite commit/checkpoint work. Default journal means a fresh SQLite connection's journal (reported below). NORMAL/OFF are diagnostic controls, NOT production settings.\n\n| sync | journal | indexes | audit | rows | payload bytes | audit bytes | payload bytes/row | audit bytes/row | begin ms | SQL ms | commit ms | DB bytes | WAL bytes |\n|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    for synchronous in ["FULL", "NORMAL", "OFF"] {
        for wal in [false, true] {
            for indexed in [false, true] {
                for compact in [false, true] {
                    let path = dir.join(format!("{synchronous}-{wal}-{indexed}-{compact}.sqlite"));
                    let mut c = Connection::open(&path).unwrap();
                    if wal {
                        c.pragma_update(None, "journal_mode", "WAL").unwrap();
                    }
                    c.pragma_update(None, "synchronous", synchronous).unwrap();
                    let journal: String = c.query_row("PRAGMA journal_mode", [], |r| r.get(0)).unwrap();
                    c.execute_batch("CREATE TABLE current_decisions(identity_key TEXT PRIMARY KEY,root TEXT NOT NULL,scheduled_at REAL,rule_id TEXT,preview INTEGER NOT NULL,payload TEXT NOT NULL,updated_at REAL NOT NULL); CREATE TABLE audit(id INTEGER PRIMARY KEY AUTOINCREMENT,occurred_at REAL NOT NULL,kind TEXT NOT NULL,payload TEXT NOT NULL);").unwrap();
                    if indexed {
                        c.execute_batch("CREATE INDEX decisions_due ON current_decisions(scheduled_at,identity_key) WHERE scheduled_at IS NOT NULL; CREATE INDEX decisions_rule ON current_decisions(rule_id,scheduled_at,identity_key) WHERE scheduled_at IS NOT NULL; CREATE INDEX decisions_preview ON current_decisions(preview,scheduled_at,identity_key) WHERE scheduled_at IS NOT NULL; CREATE INDEX decisions_root ON current_decisions(root); CREATE INDEX audit_order ON audit(occurred_at,id); CREATE INDEX decision_identity ON audit(json_extract(payload,'$.item.volumeIdentifier') COLLATE NOCASE,json_extract(payload,'$.item.resourceIdentifier') COLLATE NOCASE,id DESC) WHERE kind IN ('previewMatch','schedulingDecision');").unwrap();
                    }
                    let data: Vec<_> = (0..ROWS).map(|n| {
                        let key = format!("00000000-0000-0000-0000-000000000001:{n:08x}");
                        let item = serde_json::json!({"volumeIdentifier":"00000000-0000-0000-0000-000000000001","resourceIdentifier":format!("{n:08x}"),"pathHint":format!("C:/Synthetic/Root/item-{n}"),"creationTime":1,"generation":1});
                        let payload = serde_json::json!({"item":item,"scheduledAt":1000,"ruleID":"synthetic-rule","preview":false,"basis":"modified","projectContext":null,"override":null,"suppressionReason":null,"diagnosticContext":"x".repeat(768)}).to_string();
                        let audit = if compact { serde_json::json!({"version":1,"identityKey":key,"item":item,"creationTime":1,"generation":1,"scheduledAt":1000,"ruleID":"synthetic-rule","preview":false}).to_string() } else { payload.clone() };
                        (key, payload, audit)
                    }).collect();
                    let payload_bytes: usize = data.iter().map(|r| r.1.len()).sum();
                    let audit_bytes: usize = data.iter().map(|r| r.2.len()).sum();
                    let (mut begin_ms, mut sql_ms, mut commit_ms) = (0.0, 0.0, 0.0);
                    for batch in data.chunks(BATCH) {
                        let begin = Instant::now();
                        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate).unwrap();
                        begin_ms += begin.elapsed().as_secs_f64() * 1000.0;
                        {
                            let mut decision = tx.prepare_cached("INSERT INTO current_decisions VALUES(?1,'synthetic-root',1000,'synthetic-rule',0,?2,1)").unwrap();
                            let mut audit = tx.prepare_cached("INSERT INTO audit(occurred_at,kind,payload) VALUES(1,'schedulingDecision',?1)").unwrap();
                            let sql = Instant::now();
                            for (key, payload, event) in batch {
                                decision.execute(params![key, payload]).unwrap();
                                audit.execute([event]).unwrap();
                            }
                            sql_ms += sql.elapsed().as_secs_f64() * 1000.0;
                        }
                        let commit = Instant::now();
                        tx.commit().unwrap();
                        commit_ms += commit.elapsed().as_secs_f64() * 1000.0;
                    }
                    let page_count: i64 = c.query_row("PRAGMA page_count", [], |r| r.get(0)).unwrap();
                    let page_size: i64 = c.query_row("PRAGMA page_size", [], |r| r.get(0)).unwrap();
                    let wal_bytes = fs::metadata(path.with_extension("sqlite-wal")).map_or(0, |m| m.len());
                    report.push_str(&format!("| {synchronous} | {journal} | {} | {} | {ROWS} | {payload_bytes} | {audit_bytes} | {:.3} | {:.3} | {begin_ms:.3} | {sql_ms:.3} | {commit_ms:.3} | {} | {wal_bytes} |\n", if indexed { "maintained" } else { "PK only" }, if compact { "compact" } else { "full duplicate" }, payload_bytes as f64 / ROWS as f64, audit_bytes as f64 / ROWS as f64, page_count * page_size));
                    drop(c);
                    fs::remove_file(path).unwrap();
                }
            }
        }
    }
    print!("{report}");
    if let Some(path) = std::env::var_os("TINYPRUNE_BENCH_OUT") {
        OpenOptions::new().create(true).append(true).open(path).unwrap().write_all(report.as_bytes()).unwrap();
    }
    fs::remove_dir_all(dir).unwrap();
}
