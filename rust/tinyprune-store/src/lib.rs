//! Durable metadata-only SQLite authority for the unreleased Rust agent.
mod codec;
mod schema;
use codec::*;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, Transaction};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
};

// The diagnostic sink is optional, metadata-only and independent of database durability.
static PHASE_SINK: std::sync::LazyLock<Option<Mutex<std::fs::File>>> =
    std::sync::LazyLock::new(|| {
        let path = std::env::var_os("TINYPRUNE_PHASE_LOG")?;
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .ok()
            .map(Mutex::new)
    });

fn decision_phase(
    phase: &str,
    elapsed: std::time::Duration,
    ended: std::time::SystemTime,
    rows: usize,
    changed: usize,
    payload_bytes: usize,
    audit_bytes: usize,
) {
    use std::io::Write as _;
    let Some(sink) = PHASE_SINK.as_ref() else { return };
    let end_ms = ended
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64() * 1000.0);
    if let Ok(mut file) = sink.lock() {
        let _ = writeln!(
            file,
            "{{\"phase\":\"{phase}\",\"ms\":{:.3},\"items\":{rows},\"changed_rows\":{changed},\"payload_bytes\":{payload_bytes},\"audit_bytes\":{audit_bytes},\"end_ms\":{end_ms:.0}}}",
            elapsed.as_secs_f64() * 1000.0
        );
    }
}
use tinyprune_agent::{AgentAudit, AgentStore};
use tinyprune_core::{
    config, config_plan,
    path::WindowsKey,
    resolve::*,
    rule::*,
    scheduler::{Observation, ObservationStore, Project},
    trash::*,
    uuid::Uuid,
};
pub type Result<T, E = String> = std::result::Result<T, E>;
pub use schema::VERSION as SCHEMA_VERSION;
fn sql<T>(r: rusqlite::Result<T>) -> Result<T> {
    r.map_err(|e| e.to_string())
}
fn finite(at: f64) -> Result<()> {
    if at.is_finite() {
        Ok(())
    } else {
        Err("Timestamp must be finite".into())
    }
}
fn hex(resource: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(resource.len() * 2);
    for byte in resource {
        text.push(DIGITS[usize::from(byte >> 4)] as char);
        text.push(DIGITS[usize::from(byte & 15)] as char);
    }
    text
}
fn key(i: &FilesystemIdentity) -> String {
    format!("{}:{}", i.volume, hex(&i.resource))
}
fn same_path(a: &str, b: &str, flavor: PathFlavor) -> bool {
    match flavor {
        PathFlavor::Posix => flavor.equal(a, b),
        PathFlavor::Windows => WindowsKey::new(a) == WindowsKey::new(b),
    }
}
fn within(path: &str, root: &str, flavor: PathFlavor) -> bool {
    match flavor {
        PathFlavor::Posix => same_path(path, root, flavor) || flavor.is_descendant(path, root),
        PathFlavor::Windows => WindowsKey::new(path).within(&WindowsKey::new(root)),
    }
}
/// Containment against one fixed root or subtree. The Windows key of the root is computed once, and
/// each tested path is normalized once, instead of normalizing both operands for every comparison.
struct Contains<'a> {
    root: &'a str,
    flavor: PathFlavor,
    root_key: Option<WindowsKey>,
}
impl<'a> Contains<'a> {
    fn new(root: &'a str, flavor: PathFlavor) -> Self {
        let root_key = (flavor == PathFlavor::Windows).then(|| WindowsKey::new(root));
        Self {
            root,
            flavor,
            root_key,
        }
    }
    fn path(&self, path: &str) -> bool {
        match &self.root_key {
            Some(root) => WindowsKey::new(path).within(root),
            None => within(path, self.root, self.flavor),
        }
    }
    /// Like `path`, reusing the already computed Windows key of the tested path when there is one.
    fn holds(&self, path: &str, key: Option<&WindowsKey>) -> bool {
        match (&self.root_key, key) {
            (Some(root), Some(key)) => key.within(root),
            _ => self.path(path),
        }
    }
    /// Strictly below the root (`PathFlavor::is_descendant`).
    fn strictly_below(&self, path: &str) -> bool {
        match &self.root_key {
            Some(root) => WindowsKey::new(path).is_descendant_of(root),
            None => self.flavor.is_descendant(path, self.root),
        }
    }
}
fn count(n: i64) -> Result<u64> {
    u64::try_from(n).map_err(|_| "Invalid persisted count".into())
}
/// Default WAL size at which scheduled maintenance should checkpoint (also SQLite's WAL truncation limit).
pub const DEFAULT_WAL_CHECKPOINT_BYTES: u64 = 64 * 1024 * 1024;
/// WAL size above which every write transaction first runs a passive checkpoint, even for callers that
/// never schedule maintenance.
pub const HARD_WAL_LIMIT_BYTES: u64 = 256 * 1024 * 1024;
/// Outcome of one WAL checkpoint attempt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    /// WAL file size when the attempt began.
    pub wal_bytes: u64,
    /// SQLite reported busy: a lock or reader stopped the checkpoint (TRUNCATE with its zero timeout).
    /// A PASSIVE checkpoint limited by a pinned reader usually reports `false`; compare the frame counts.
    pub busy: bool,
    /// Frames in the WAL after the attempt / frames backfilled into the database.
    pub log_frames: i64,
    pub checkpointed_frames: i64,
}
fn run_checkpoint(c: &Connection, mode: &str, wal_bytes: u64) -> Result<Checkpoint> {
    let (busy, log_frames, checkpointed_frames) = sql(c.query_row(
        &format!("PRAGMA wal_checkpoint({mode})"),
        [],
        |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)),
    ))?;
    Ok(Checkpoint {
        wal_bytes,
        busy: busy != 0,
        log_frames,
        checkpointed_frames,
    })
}
/// Durable store handle.
///
/// * One **writer** connection (mutex) serializes every mutation as an IMMEDIATE transaction.
/// * File-backed stores also open a second **read-only WAL** connection (its own mutex) that serves every
///   read method, so queries never wait for the writer's transactions or fsyncs. In-memory stores
///   share one connection for both roles.
///
/// Clones are `Send` and share both connections. Project slices are an explicit per-handle snapshot; call
/// `refresh_projects` before transferring ownership.
#[derive(Clone)]
pub struct Store {
    writer: Arc<Mutex<Connection>>,
    reader: Arc<Mutex<Connection>>,
    projects: Vec<Project>,
    path_flavor: PathFlavor,
    /// `<database>-wal`; `None` for in-memory stores.
    wal_path: Option<PathBuf>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct DeadlineCursor {
    pub scheduled_at: f64,
    pub identity_key: String,
}
pub struct DeadlinePage {
    pub items: Vec<TrashRequest>,
    pub next: Option<DeadlineCursor>,
}
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ReclaimTotals {
    pub items: i64,
    pub bytes: i64,
    pub known_items: i64,
    pub first_at: Option<f64>,
    pub last_at: Option<f64>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct ReclaimDay {
    pub utc_day: i64,
    pub totals: ReclaimTotals,
}
#[derive(Clone, Debug)]
pub struct AuditRecord {
    pub id: i64,
    pub occurred_at: f64,
    pub kind: String,
    pub payload: String,
}
/// One current scheduling/preview decision for a candidate identity.
#[derive(Clone, Copy, Debug)]
pub struct DecisionRow<'a> {
    pub identity: &'a FilesystemIdentity,
    /// `None` for suppressed items (kept for explanation, excluded from schedules/counts).
    pub scheduled_at: Option<f64>,
    pub rule_id: Option<&'a str>,
    pub preview: bool,
    /// Full wire explanation, persisted unreduced.
    pub explanation: &'a serde_json::Value,
}
impl AuditRecord {
    pub fn event(&self) -> Result<Option<AuditEvent>> {
        if matches!(
            self.kind.as_str(),
            "previewSkipped"
                | "notDue"
                | "safetySkipped"
                | "trashAttempted"
                | "movedToTrash"
                | "trashFailed"
        ) {
            Ok(Some(decode::<Event>(&self.payload)?.decode()?))
        } else {
            Ok(None)
        }
    }
}
const UPSERT_CANDIDATE: &str = "INSERT INTO candidates(identity_key,root,payload,path_hint,path_key) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(identity_key) DO UPDATE SET root=excluded.root,payload=excluded.payload,path_hint=excluded.path_hint,path_key=excluded.path_key WHERE payload<>excluded.payload OR root<>excluded.root";
const UPSERT_DEADLINE: &str = "INSERT INTO deadlines(identity_key,root,scheduled_at,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(identity_key) DO UPDATE SET root=excluded.root,scheduled_at=excluded.scheduled_at,payload=excluded.payload WHERE payload<>excluded.payload OR root<>excluded.root";
const INSERT_AUDIT: &str = "INSERT INTO audit(occurred_at,kind,payload) VALUES(?1,?2,?3)";
/// Keyset SQL for `decision_page`; exposed to tests so query plans can be asserted.
fn decision_page_sql(rule: bool, preview: bool, after: bool) -> String {
    format!(
        "SELECT scheduled_at,identity_key,payload FROM current_decisions WHERE scheduled_at IS NOT NULL{}{}{} ORDER BY scheduled_at,identity_key LIMIT ?",
        if rule { " AND rule_id=?" } else { "" },
        if preview { " AND preview=?" } else { "" },
        if after { " AND (scheduled_at,identity_key)>(?,?)" } else { "" },
    )
}
fn decision_count_sql(rule: bool, preview: bool) -> String {
    format!(
        "SELECT COUNT(*) FROM current_decisions WHERE scheduled_at IS NOT NULL{}{}",
        if rule { " AND rule_id=?" } else { "" },
        if preview { " AND preview=?" } else { "" },
    )
}
impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_flavor(path, PathFlavor::Posix)
    }
    pub fn open_with_flavor(path: impl AsRef<Path>, path_flavor: PathFlavor) -> Result<Self> {
        let path = path.as_ref();
        let writer = Self::prepare_writer(sql(Connection::open(path))?)?;
        let reader = sql(Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ))?;
        sql(reader.busy_timeout(std::time::Duration::from_secs(5)))?;
        let mut wal_name = path.as_os_str().to_owned();
        wal_name.push("-wal");
        Self::finish(
            Arc::new(Mutex::new(writer)),
            Arc::new(Mutex::new(reader)),
            path_flavor,
            Some(PathBuf::from(wal_name)),
        )
    }
    pub fn memory() -> Result<Self> {
        Self::memory_with_flavor(PathFlavor::Posix)
    }
    pub fn memory_with_flavor(path_flavor: PathFlavor) -> Result<Self> {
        Self::from_connection_with_flavor(sql(Connection::open_in_memory())?, path_flavor)
    }
    /// Single shared connection for both roles (in-memory databases cannot be opened twice).
    #[cfg(test)]
    fn from_connection(c: Connection) -> Result<Self> {
        Self::from_connection_with_flavor(c, PathFlavor::Posix)
    }
    fn from_connection_with_flavor(c: Connection, path_flavor: PathFlavor) -> Result<Self> {
        let shared = Arc::new(Mutex::new(Self::prepare_writer(c)?));
        Self::finish(shared.clone(), shared, path_flavor, None)
    }
    fn prepare_writer(mut c: Connection) -> Result<Connection> {
        sql(c.busy_timeout(std::time::Duration::from_secs(5)))?;
        sql(c.execute_batch(
            "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;",
        ))?;
        // Autocheckpoint would run inside the commit of whichever transaction crosses the threshold,
        // adding a database fsync to the durable commit path (minutes over a 100k-row publication on
        // Windows). Checkpoints are scheduled between jobs instead; see `checkpoint_if_needed`.
        sql(c.execute_batch(&format!(
            "PRAGMA wal_autocheckpoint=0; PRAGMA journal_size_limit={DEFAULT_WAL_CHECKPOINT_BYTES};"
        )))?;
        schema::migrate(&mut c)?;
        // Device-number identities are not restart-stable. Never execute their stale schedules.
        sql(c.execute(
            "DELETE FROM deadlines WHERE json_extract(payload,'$.identity.persistent')=0",
            [],
        ))?;
        sql(c.execute(
            "DELETE FROM observations WHERE json_extract(identity,'$.persistent')=0",
            [],
        ))?;
        sql(c.execute(
            "DELETE FROM projects WHERE json_extract(identity,'$.persistent')=0",
            [],
        ))?;
        Ok(c)
    }
    fn finish(
        writer: Arc<Mutex<Connection>>,
        reader: Arc<Mutex<Connection>>,
        path_flavor: PathFlavor,
        wal_path: Option<PathBuf>,
    ) -> Result<Self> {
        let mut store = Self {
            writer,
            reader,
            projects: vec![],
            path_flavor,
            wal_path,
        };
        ensure_keys(&*store.lock()?, path_flavor)?;
        store.refresh_projects()?;
        Ok(store)
    }
    /// The writer connection.
    fn lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.writer
            .lock()
            .map_err(|_| "Store mutex poisoned".into())
    }
    /// The read connection (independent of the writer for file-backed stores).
    fn read(&self) -> Result<MutexGuard<'_, Connection>> {
        self.reader
            .lock()
            .map_err(|_| "Store reader mutex poisoned".into())
    }
    fn transaction<T>(&self, f: impl FnOnce(&Transaction<'_>) -> Result<T>) -> Result<T> {
        let mut c = self.lock()?;
        self.checkpoint_backstop(&c);
        let tx = sql(c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
        let value = f(&tx)?;
        sql(tx.commit())?;
        Ok(value)
    }
    /// A consistent deferred read snapshot on the read connection.
    fn read_transaction<T>(&self, f: impl FnOnce(&Transaction<'_>) -> Result<T>) -> Result<T> {
        let mut c = self.read()?;
        let tx = sql(c.transaction())?;
        let value = f(&tx)?;
        sql(tx.commit())?;
        Ok(value)
    }
    /// Logical SQLite database pages, excluding WAL/SHM and filesystem allocation overhead.
    pub fn database_bytes(&self) -> Result<u64> {
        let c = self.read()?;
        let pages: i64 = sql(c.query_row("PRAGMA page_count", [], |r| r.get(0)))?;
        let size: i64 = sql(c.query_row("PRAGMA page_size", [], |r| r.get(0)))?;
        u64::try_from(pages)
            .ok()
            .zip(u64::try_from(size).ok())
            .and_then(|(pages, size)| pages.checked_mul(size))
            .ok_or_else(|| "Invalid database page size/count".into())
    }
    /// Size of the write-ahead log file (0 for in-memory stores or when no log file exists).
    pub fn wal_bytes(&self) -> u64 {
        self.wal_path
            .as_ref()
            .and_then(|path| std::fs::metadata(path).ok())
            .map_or(0, |meta| meta.len())
    }
    /// Cheap bounded maintenance between write jobs: when the WAL file is larger than `limit_bytes`,
    /// runs one `PRAGMA wal_checkpoint(PASSIVE)` (otherwise does nothing).
    ///
    /// Autocheckpoint is disabled on the writer, so no commit ever pays for a checkpoint inside the
    /// durable commit path; this is the only place (besides [`Store::checkpoint_idle`] and the
    /// [`HARD_WAL_LIMIT_BYTES`] backstop) that checkpoints. PASSIVE never waits for readers or writers of
    /// other connections and never blocks the read connection: it backfills as far as the oldest reader
    /// snapshot allows and reports `busy` when it could not finish. It is never run inside a write
    /// transaction (it takes the writer mutex between transactions). Durability is unchanged:
    /// `synchronous=FULL` still applies to every commit and to the checkpoint's database sync.
    ///
    /// WAL size bound: a checkpoint is requested whenever a caller finds more than `limit_bytes`, so the
    /// WAL stays within `limit_bytes` + the largest single write transaction (about 25 MiB for a 4096-row
    /// decision page) + whatever a long-lived reader snapshot pins. Callers that never invoke this are
    /// still bounded by `HARD_WAL_LIMIT_BYTES` (checked before every write transaction).
    pub fn checkpoint_if_needed(&self, limit_bytes: u64) -> Result<Option<Checkpoint>> {
        let wal_bytes = self.wal_bytes();
        if wal_bytes <= limit_bytes {
            return Ok(None);
        }
        let c = self.lock()?;
        run_checkpoint(&c, "PASSIVE", wal_bytes).map(Some)
    }
    /// Idle-time maintenance: backfills the whole WAL and truncates the file with
    /// `PRAGMA wal_checkpoint(TRUNCATE)` using a zero busy timeout, so an active reader makes it return
    /// `busy` immediately instead of waiting. Does nothing when the WAL file is empty or absent.
    pub fn checkpoint_idle(&self) -> Result<Option<Checkpoint>> {
        let wal_bytes = self.wal_bytes();
        if wal_bytes == 0 {
            return Ok(None);
        }
        let c = self.lock()?;
        sql(c.busy_timeout(std::time::Duration::ZERO))?;
        let result = run_checkpoint(&c, "TRUNCATE", wal_bytes);
        sql(c.busy_timeout(std::time::Duration::from_secs(5)))?;
        result.map(Some)
    }
    /// Safety net for callers that never schedule checkpoints (autocheckpoint is off). Best effort:
    /// a failed or busy checkpoint only means the WAL stays larger until the next attempt.
    fn checkpoint_backstop(&self, c: &Connection) {
        let wal_bytes = self.wal_bytes();
        if wal_bytes > HARD_WAL_LIMIT_BYTES {
            let _ = run_checkpoint(c, "PASSIVE", wal_bytes);
        }
    }
    pub fn schema_version(&self) -> Result<i64> {
        sql(self
            .read()?
            .query_row("PRAGMA user_version", [], |r| r.get(0)))
    }
    pub fn runtime_state(&self) -> Result<(u64, Option<f64>, u32)> {
        let (revision, until, retention): (i64, Option<f64>, u32) = sql(self.read()?.query_row(
            "SELECT revision,paused_until,retention_days FROM settings WHERE id=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        ))?;
        Ok((
            u64::try_from(revision).map_err(|_| "Invalid policy revision")?,
            until,
            retention,
        ))
    }
    /// Atomically replaces operational policy and runtime settings, rejecting stale clients.
    pub fn replace_policy(
        &self,
        policy: &PolicySnapshot,
        expected_revision: u64,
        paused_until: Option<f64>,
        retention_days: u32,
        at: f64,
    ) -> Result<u64> {
        finite(at)?;
        finite(policy.settings.default_grace_period_seconds)?;
        if let Some(until) = paused_until {
            finite(until)?;
        }
        if policy.settings.default_grace_period_seconds < 0.0 {
            return Err("Negative grace".into());
        }
        let expected = i64::try_from(expected_revision).map_err(|_| "Policy revision overflow")?;
        self.transaction(|tx| {
            let revision:i64=sql(tx.query_row("SELECT revision FROM settings WHERE id=1",[],|r|r.get(0)))?;
            if revision!=expected { return Err("Policy revision conflict".into()); }
            let next=revision.checked_add(1).ok_or("Policy revision overflow")?;
            sql(tx.execute_batch("DELETE FROM rules; DELETE FROM overrides;"))?;
            replace_roots(tx, &policy.managed_roots, self.path_flavor)?;
            let rules=policy.rules.iter().map(Rule::from).collect::<Vec<_>>();
            let overrides=policy.overrides.iter().map(Override::from).collect::<Vec<_>>();
            for (n,(rule,payload)) in policy.rules.iter().zip(&rules).enumerate() { sql(tx.execute("INSERT INTO rules VALUES(?1,?2,?3)",params![rule.id.to_string(),n as i64,encode(payload)?]))?; }
            for (n,(o,payload)) in policy.overrides.iter().zip(&overrides).enumerate() { sql(tx.execute("INSERT INTO overrides VALUES(?1,?2,?3,?4,?5)",params![o.id.to_string(),n as i64,o.identity.as_ref().map(key),o.path,encode(payload)?]))?; }
            sql(tx.execute("UPDATE settings SET paused=?1,hidden=?2,grace=?3,windows=?4,revision=?5,paused_until=?6,retention_days=?7 WHERE id=1",params![policy.globally_paused,policy.settings.protect_hidden_files,policy.settings.default_grace_period_seconds,policy.settings.path_flavor==PathFlavor::Windows,next,paused_until,retention_days]))?;
            record(tx,at,"policyReplaced",&encode(&serde_json::json!({"rules":rules,"overrides":overrides,"roots":policy.managed_roots,"paused":policy.globally_paused,"hidden":policy.settings.protect_hidden_files,"grace":policy.settings.default_grace_period_seconds,"windows":policy.settings.path_flavor==PathFlavor::Windows,"revision":next,"pausedUntil":paused_until,"retentionDays":retention_days}))?)?;
            Ok(next as u64)
        })
    }
    /// Ascending immutable row-id keyset; the last returned id is the next cursor.
    pub fn audit_page(
        &self,
        after_id: Option<i64>,
        limit: std::num::NonZeroUsize,
    ) -> Result<Vec<AuditRecord>> {
        let c = self.read()?;
        let mut s=sql(c.prepare("SELECT id,occurred_at,kind,payload FROM audit WHERE (?1 IS NULL OR id>?1) ORDER BY id LIMIT ?2"))?;
        let rows = sql(s.query_map(params![after_id, limit.get() as i64], |r| {
            Ok(AuditRecord {
                id: r.get(0)?,
                occurred_at: r.get(1)?,
                kind: r.get(2)?,
                payload: r.get(3)?,
            })
        }))?;
        rows.map(sql).collect()
    }
    pub fn put_rule(&self, rule: &LifetimeRule, at: f64) -> Result<()> {
        let payload = encode(&Rule::from(rule))?;
        self.transaction(|tx| { sql(tx.execute("INSERT INTO rules VALUES(?1,COALESCE((SELECT position FROM rules WHERE id=?1),(SELECT COALESCE(MAX(position),-1)+1 FROM rules)),?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",params![rule.id.to_string(),payload]))?; record(tx,at,"ruleMutation",&payload)?; Ok(()) })
    }
    pub fn remove_rule(&self, id: Uuid, at: f64) -> Result<()> {
        self.transaction(|tx| {
            sql(tx.execute("DELETE FROM rules WHERE id=?", [id.to_string()]))?;
            record(tx, at, "ruleRemoved", &encode(&id.to_string())?)?;
            Ok(())
        })
    }
    pub fn put_override(&self, o: &ItemPolicyOverride, at: f64) -> Result<()> {
        let payload = encode(&Override::from(o))?;
        self.transaction(|tx| { sql(tx.execute("INSERT INTO overrides VALUES(?1,COALESCE((SELECT position FROM overrides WHERE id=?1),(SELECT COALESCE(MAX(position),-1)+1 FROM overrides)),?2,?3,?4) ON CONFLICT(id) DO UPDATE SET identity_key=excluded.identity_key,path_hint=excluded.path_hint,payload=excluded.payload",params![o.id.to_string(),o.identity.as_ref().map(key),o.path,payload]))?; record(tx,at,"overrideMutation",&payload)?; Ok(()) })
    }
    pub fn remove_override(&self, id: Uuid, at: f64) -> Result<()> {
        self.transaction(|tx| {
            sql(tx.execute("DELETE FROM overrides WHERE id=?", [id.to_string()]))?;
            record(tx, at, "overrideRemoved", &encode(&id.to_string())?)?;
            Ok(())
        })
    }
    /// Root validation/canonical resolution is the platform caller's responsibility.
    pub fn replace_roots(&self, roots: &[String], at: f64) -> Result<()> {
        self.transaction(|tx| {
            replace_roots(tx, roots, self.path_flavor)?;
            record(tx, at, "managedRootsMutation", &encode(&roots)?)?;
            Ok(())
        })
    }
    pub fn set_settings(&self, paused: bool, settings: AgentSettings, at: f64) -> Result<()> {
        finite(settings.default_grace_period_seconds)?;
        if settings.default_grace_period_seconds < 0.0 {
            return Err("Negative grace".into());
        }
        self.transaction(|tx| {
            sql(tx.execute(
                "UPDATE settings SET paused=?1,hidden=?2,grace=?3,windows=?4 WHERE id=1",
                params![
                    paused,
                    settings.protect_hidden_files,
                    settings.default_grace_period_seconds,
                    settings.path_flavor == PathFlavor::Windows
                ],
            ))?;
            record(
                tx,
                at,
                "settingsMutation",
                &encode(&(
                    paused,
                    settings.protect_hidden_files,
                    settings.default_grace_period_seconds,
                    settings.path_flavor == PathFlavor::Windows,
                ))?,
            )?;
            Ok(())
        })
    }
    pub fn export_config(&mut self) -> Result<String> {
        let p = self.load_snapshot()?;
        Ok(config::render(&p.rules, &p.managed_roots, &p.overrides))
    }
    /// Import replaces config-expressible policy atomically, with Preview rules by default.
    pub fn import_config(&self, text: &str, home: &str, at: f64) -> Result<()> {
        let document = config::ConfigDocument::parse(text, home)
            .map_err(|e| format!("{:?}: {}", e.line, e.message))?;
        let rules =
            config_plan::document_rules(&document, RuleState::Preview).map_err(|e| e.name())?;
        self.transaction(|tx| {
            sql(tx.execute_batch("DELETE FROM rules; DELETE FROM overrides; DELETE FROM roots;"))?;
            for (n, root) in document.roots.iter().enumerate() {
                sql(tx.execute(
                    "INSERT INTO roots VALUES(?1,?2)",
                    params![root.path, n as i64],
                ))?;
            }
            for (n, r) in rules.iter().enumerate() {
                sql(tx.execute(
                    "INSERT INTO rules VALUES(?1,?2,?3)",
                    params![r.id.to_string(), n as i64, encode(&Rule::from(r))?],
                ))?;
            }
            for (n, e) in document.exceptions.iter().enumerate() {
                let o = ItemPolicyOverride::new(
                    config::rule_id("exception", &e.path),
                    None,
                    &e.path,
                    ItemOverridePolicy::Keep {
                        protect_descendants: e.protect_descendants,
                    },
                );
                sql(tx.execute(
                    "INSERT INTO overrides VALUES(?1,?2,NULL,?3,?4)",
                    params![
                        o.id.to_string(),
                        n as i64,
                        o.path,
                        encode(&Override::from(&o))?
                    ],
                ))?;
            }
            record(tx, at, "configImported", &encode(&text)?)?;
            Ok(())
        })
    }
    /// Replaces every candidate of `root` (upsert changed rows, delete vanished) in one transaction.
    pub fn replace_candidates(
        &self,
        root: &str,
        candidates: &[RuleCandidate],
        at: f64,
    ) -> Result<()> {
        self.transaction(|tx| {
            let root = stored_root(tx, root, self.path_flavor)?;
            let mut seen = HashSet::with_capacity(candidates.len());
            {
                let mut up = sql(tx.prepare_cached(UPSERT_CANDIDATE))?;
                for c in candidates {
                    let k = key(&c.identity);
                    sql(up.execute(params![
                        &k,
                        &root,
                        encode(&Candidate::from(c))?,
                        &c.identity.path_hint,
                        path_key(self.path_flavor, &c.identity.path_hint)
                    ]))?;
                    seen.insert(k);
                }
            }
            let existing = strings(
                tx,
                "SELECT identity_key FROM candidates WHERE root=?",
                [&root],
            )?;
            let mut del = sql(tx.prepare_cached("DELETE FROM candidates WHERE identity_key=?"))?;
            for k in existing.iter().filter(|k| !seen.contains(*k)) {
                sql(del.execute([k]))?;
            }
            record(
                tx,
                at,
                "candidatesPublished",
                &encode(&(root, candidates.len()))?,
            )?;
            Ok(())
        })
    }
    /// Publishes a completed metadata-only subtree scan, including an empty vanished subtree.
    ///
    /// Only rows whose payload changed are rewritten; vanished rows (and their current decisions) are
    /// deleted. Returns the number of inserted + changed + deleted rows; `0` means identical and
    /// nothing, including audit, was written.
    pub fn publish_candidate_subtree(
        &self,
        path: &str,
        candidates: &[RuleCandidate],
        at: f64,
    ) -> Result<usize> {
        self.transaction(|tx| {
            let flavor = self.path_flavor;
            let subtree = Contains::new(path, flavor);
            let mut seen = HashSet::with_capacity(candidates.len());
            let changed =
                upsert_candidates_in(tx, flavor, candidates, Some(&subtree), Some(&mut seen))?;
            let deleted = delete_subtree(tx, "candidates", flavor, path, |k, hint| {
                !seen.contains(k) && subtree.path(hint)
            })?;
            let total = changed + deleted;
            if total > 0 {
                record(
                    tx,
                    at,
                    "candidateSubtreePublished",
                    &encode(&(path, candidates.len()))?,
                )?;
            }
            Ok(total)
        })
    }
    /// Inserts or rewrites changed candidate rows (each mapped to its longest managed root) without
    /// retiring any other row. Returns the number of inserted + changed rows; an audit record is
    /// written only when that is nonzero.
    pub fn upsert_candidates(&self, candidates: &[RuleCandidate], at: f64) -> Result<usize> {
        self.transaction(|tx| {
            let changed = upsert_candidates_in(tx, self.path_flavor, candidates, None, None)?;
            if changed > 0 {
                record(tx, at, "candidatesUpserted", &encode(&candidates.len())?)?;
            }
            Ok(changed)
        })
    }
    pub fn candidate_count(&self) -> Result<u64> {
        count(sql(self.read()?.query_row(
            "SELECT COUNT(*) FROM candidates",
            [],
            |r| r.get(0),
        ))?)
    }
    pub fn audit_recent(&self, limit: std::num::NonZeroUsize) -> Result<Vec<AuditRecord>> {
        let c = self.read()?;
        let mut s = sql(
            c.prepare("SELECT id,occurred_at,kind,payload FROM audit ORDER BY id DESC LIMIT ?")
        )?;
        let rows = sql(s.query_map([limit.get() as i64], |r| {
            Ok(AuditRecord {
                id: r.get(0)?,
                occurred_at: r.get(1)?,
                kind: r.get(2)?,
                payload: r.get(3)?,
            })
        }))?;
        rows.map(sql).collect()
    }
    pub fn candidate_page(
        &self,
        root: &str,
        after: Option<&str>,
        limit: std::num::NonZeroUsize,
    ) -> Result<Vec<(String, RuleCandidate)>> {
        let c = self.read()?;
        let root = stored_root(&c, root, self.path_flavor)?;
        let mut s=sql(c.prepare("SELECT identity_key,payload FROM candidates WHERE root=?1 AND (?2 IS NULL OR identity_key>?2) ORDER BY identity_key LIMIT ?3"))?;
        let rows = sql(s.query_map(params![root, after, limit.get() as i64], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        }))?;
        rows.map(|r| {
            let (k, p) = sql(r)?;
            Ok((k, decode::<Candidate>(&p)?.decode()?))
        })
        .collect()
    }
    pub fn deadline_page(
        &self,
        after: Option<&DeadlineCursor>,
        limit: std::num::NonZeroUsize,
    ) -> Result<DeadlinePage> {
        let c = self.read()?;
        let mut s=sql(c.prepare("SELECT scheduled_at,identity_key,payload FROM deadlines WHERE (?1 IS NULL OR (scheduled_at,identity_key)>(?1,?2)) ORDER BY scheduled_at,identity_key LIMIT ?3"))?;
        let rows = sql(s.query_map(
            params![
                after.map(|a| a.scheduled_at),
                after.map(|a| &a.identity_key),
                limit.get() as i64 + 1
            ],
            |r| {
                Ok((
                    r.get::<_, f64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        ))?;
        let mut rows = rows.map(sql).collect::<Result<Vec<_>>>()?;
        let more = rows.len() > limit.get();
        rows.truncate(limit.get());
        let next = if more {
            rows.last().map(|(at, k, _)| DeadlineCursor {
                scheduled_at: *at,
                identity_key: k.clone(),
            })
        } else {
            None
        };
        let items = rows
            .into_iter()
            .map(|(_, _, p)| decode::<Request>(&p)?.decode())
            .collect::<Result<_>>()?;
        Ok(DeadlinePage { items, next })
    }
    /// The richer client decision DTO is supplied by the runtime; persist its full JSON without reduction.
    pub fn record_decision(
        &self,
        at: f64,
        preview: bool,
        full_explanation: &serde_json::Value,
    ) -> Result<()> {
        self.transaction(|tx| {
            record(
                tx,
                at,
                if preview {
                    "previewMatch"
                } else {
                    "schedulingDecision"
                },
                &encode(full_explanation)?,
            )?;
            Ok(())
        })
    }
    /// Upserts current decisions in ONE transaction with prepared statements.
    ///
    /// Rows whose persisted payload/schedule/rule/preview are unchanged write nothing. New or changed
    /// rows are upserted and append a compact, versioned `schedulingDecision`/`previewMatch` audit
    /// record in the same FULL transaction. Full explanations live in the current projection.
    /// Returns the number of rows recorded. Rows whose candidate row no longer
    /// exists (checked inside the same transaction) are silently skipped, so a decision evaluated just
    /// before a Trash/removal can never resurrect an orphan; the schema also rejects orphan inserts.
    pub fn put_decisions(&self, at: f64, rows: &[DecisionRow<'_>]) -> Result<usize> {
        finite(at)?;
        let logging = PHASE_SINK.is_some();
        let waiting = logging.then(std::time::Instant::now);
        let mut c = self.lock()?;
        self.checkpoint_backstop(&c);
        let tx = sql(c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
        let begin_elapsed = waiting.map(|start| (start.elapsed(), std::time::SystemTime::now()));
        let started = logging.then(std::time::Instant::now);
        let (recorded, payload_bytes, audit_bytes) = (|| {
            let mut find = sql(tx.prepare_cached(
                "SELECT payload,scheduled_at,rule_id,preview FROM current_decisions WHERE identity_key=?",
            ))?;
            let mut root_of =
                sql(tx.prepare_cached("SELECT root FROM candidates WHERE identity_key=?"))?;
            let mut upsert = sql(tx.prepare_cached(
                "INSERT INTO current_decisions(identity_key,root,scheduled_at,rule_id,preview,payload,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(identity_key) DO UPDATE SET root=excluded.root,scheduled_at=excluded.scheduled_at,rule_id=excluded.rule_id,preview=excluded.preview,payload=excluded.payload,updated_at=excluded.updated_at",
            ))?;
            let mut audit = sql(tx.prepare_cached(INSERT_AUDIT))?;
            let mut recorded = 0usize;
            let mut payload_bytes = 0usize;
            let mut audit_bytes = 0usize;
            for row in rows {
                if let Some(scheduled_at) = row.scheduled_at {
                    finite(scheduled_at)?;
                }
                let k = key(row.identity);
                let Some(root): Option<String> =
                    sql(root_of.query_row([&k], |r| r.get(0)).optional())?
                else {
                    continue;
                };
                let payload = encode(row.explanation)?;
                let existing: Option<(String, Option<f64>, Option<String>, bool)> = sql(find
                    .query_row([&k], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                    })
                    .optional())?;
                if let Some((old, scheduled_at, rule_id, preview)) = &existing {
                    if *old == payload
                        && *scheduled_at == row.scheduled_at
                        && rule_id.as_deref() == row.rule_id
                        && *preview == row.preview
                    {
                        continue;
                    }
                }
                let compact = encode(&serde_json::json!({
                    "version": 1,
                    "identityKey": &k,
                    "creationTime": row.identity.creation_time,
                    "item": {
                        "volumeIdentifier": row.identity.volume.to_string(),
                        "resourceIdentifier": hex(&row.identity.resource),
                        "pathHint": &row.identity.path_hint,
                        "creationTime": row.identity.creation_time,
                        "generation": row.identity.generation,
                        "isPersistent": row.identity.is_persistent
                    },
                    "generation": row.identity.generation,
                    "scheduledAt": row.scheduled_at,
                    "ruleID": row.rule_id,
                    "preview": row.preview
                }))?;
                sql(upsert.execute(params![
                    &k,
                    root,
                    row.scheduled_at,
                    row.rule_id,
                    row.preview,
                    &payload,
                    at
                ]))?;
                sql(audit.execute(params![
                    at,
                    if row.preview {
                        "previewMatch"
                    } else {
                        "schedulingDecision"
                    },
                    &compact
                ]))?;
                recorded += 1;
                payload_bytes += payload.len();
                audit_bytes += compact.len();
            }
            Ok::<_, String>((recorded, payload_bytes, audit_bytes))
        })()?;
        let sql_elapsed = started.map(|start| (start.elapsed(), std::time::SystemTime::now()));
        let committing = logging.then(std::time::Instant::now);
        sql(tx.commit())?;
        // Emit only after commit: diagnostics never extend the write transaction.
        if let Some((elapsed, ended)) =
            committing.map(|start| (start.elapsed(), std::time::SystemTime::now()))
        {
            let (begin_elapsed, begin_ended) = begin_elapsed.unwrap();
            let (sql_elapsed, sql_ended) = sql_elapsed.unwrap();
            decision_phase("store.decisions.begin", begin_elapsed, begin_ended, rows.len(), recorded, payload_bytes, audit_bytes);
            decision_phase("store.decisions.sql", sql_elapsed, sql_ended, rows.len(), recorded, payload_bytes, audit_bytes);
            decision_phase("store.decisions.commit", elapsed, ended, rows.len(), recorded, payload_bytes, audit_bytes);
        }
        Ok(recorded)
    }
    /// `(active, preview, active_soon)` over scheduled decisions. `active_soon` counts active
    /// decisions due at or before `soon_until` (overdue included, as the Swift summary does); `_now` is
    /// accepted for call-site symmetry with the Swift API and is not needed by the indexed query.
    pub fn decision_counts(&self, _now: f64, soon_until: f64) -> Result<(u64, u64, u64)> {
        finite(soon_until)?;
        let c = self.read()?;
        let one = |query: &str, params: &[&dyn rusqlite::ToSql]| -> Result<u64> {
            count(sql(c.query_row(query, params, |r| r.get(0)))?)
        };
        Ok((
            one("SELECT COUNT(*) FROM current_decisions WHERE preview=0 AND scheduled_at IS NOT NULL", &[])?,
            one("SELECT COUNT(*) FROM current_decisions WHERE preview=1 AND scheduled_at IS NOT NULL", &[])?,
            one(
                "SELECT COUNT(*) FROM current_decisions WHERE preview=0 AND scheduled_at IS NOT NULL AND scheduled_at<=?1",
                &[&soon_until],
            )?,
        ))
    }
    /// Per-rule `(rule_id, matches, due)` for scheduled decisions; `due` is `scheduled_at <= now`.
    pub fn decision_rule_stats(&self, now: f64) -> Result<Vec<(String, u64, u64)>> {
        finite(now)?;
        let c = self.read()?;
        let mut s = sql(c.prepare("SELECT rule_id,COUNT(*),COALESCE(SUM(scheduled_at<=?1),0) FROM current_decisions WHERE scheduled_at IS NOT NULL AND rule_id IS NOT NULL GROUP BY rule_id ORDER BY rule_id"))?;
        let rows = sql(s.query_map([now], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        }))?;
        rows.map(|r| {
            let (rule, matches, due) = sql(r)?;
            Ok((rule, count(matches)?, count(due)?))
        })
        .collect()
    }
    /// Keyset page of scheduled decisions ordered by `(scheduled_at, identity_key)`; the cursor is the
    /// last returned pair. The second value is the total matching the filters, ignoring the cursor.
    #[allow(clippy::type_complexity)]
    pub fn decision_page(
        &self,
        rule_id: Option<&str>,
        preview: Option<bool>,
        after: Option<(f64, String)>,
        limit: std::num::NonZeroUsize,
    ) -> Result<(Vec<(f64, String, serde_json::Value)>, u64)> {
        let c = self.read()?;
        let mut filter: Vec<Box<dyn rusqlite::ToSql>> = vec![];
        if let Some(rule) = rule_id {
            filter.push(Box::new(rule.to_owned()));
        }
        if let Some(preview) = preview {
            filter.push(Box::new(preview));
        }
        let total = count(sql(c.query_row(
            &decision_count_sql(rule_id.is_some(), preview.is_some()),
            rusqlite::params_from_iter(filter.iter().map(|p| p.as_ref())),
            |r| r.get(0),
        ))?)?;
        let mut args = filter;
        if let Some((at, k)) = &after {
            finite(*at)?;
            args.push(Box::new(*at));
            args.push(Box::new(k.clone()));
        }
        args.push(Box::new(limit.get() as i64));
        let mut s = sql(c.prepare_cached(&decision_page_sql(
            rule_id.is_some(),
            preview.is_some(),
            after.is_some(),
        )))?;
        let rows = sql(s.query_map(
            rusqlite::params_from_iter(args.iter().map(|p| p.as_ref())),
            |r| {
                Ok((
                    r.get::<_, f64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        ))?;
        let items = rows
            .map(|r| {
                let (at, k, payload) = sql(r)?;
                Ok((at, k, decode::<serde_json::Value>(&payload)?))
            })
            .collect::<Result<_>>()?;
        Ok((items, total))
    }
    /// Latest full wire explanation for a stable identity, excluding conflicting identity guards.
    /// The current decision row wins; the audit history is the fallback.
    pub fn latest_decision(
        &self,
        identity: &FilesystemIdentity,
    ) -> Result<Option<serde_json::Value>> {
        let guard_ok = |value: &serde_json::Value| {
            let item = &value["item"];
            !(identity
                .creation_time
                .zip(item["creationTime"].as_f64())
                .is_some_and(|(a, b)| a != b)
                || identity
                    .generation
                    .zip(item["generation"].as_u64())
                    .is_some_and(|(a, b)| u64::from(a) != b))
        };
        let c = self.read()?;
        let current: Option<String> = sql(c
            .query_row(
                "SELECT payload FROM current_decisions WHERE identity_key=?",
                [key(identity)],
                |r| r.get(0),
            )
            .optional())?;
        if let Some(payload) = current {
            let value: serde_json::Value = decode(&payload)?;
            if guard_ok(&value) {
                return Ok(Some(value));
            }
        }
        let mut s=sql(c.prepare("SELECT payload FROM audit WHERE kind IN ('previewMatch','schedulingDecision') AND json_extract(payload,'$.item.volumeIdentifier')=?1 COLLATE NOCASE AND json_extract(payload,'$.item.resourceIdentifier')=?2 COLLATE NOCASE ORDER BY id DESC"))?;
        let rows = sql(s.query_map(
            params![identity.volume.to_string(), hex(&identity.resource)],
            |r| r.get::<_, String>(0),
        ))?;
        for payload in rows {
            let value: serde_json::Value = decode(&sql(payload)?)?;
            if !(value["version"] == 1 && value.get("identityKey").is_some()) && guard_ok(&value) {
                return Ok(Some(value));
            }
        }
        Ok(None)
    }
    /// Removes at most 256 expired activity rows; independent reclaim history is never pruned.
    /// Retention `0` means "keep forever" (Swift `AgentSettings`), so it prunes nothing regardless of `before`.
    pub fn prune_audit(&self, before: f64) -> Result<usize> {
        finite(before)?;
        self.transaction(|tx| {
            let retention: u32 = sql(tx.query_row("SELECT retention_days FROM settings WHERE id=1", [], |r| r.get(0)))?;
            if retention == 0 {
                return Ok(0);
            }
            sql(tx.execute("DELETE FROM audit WHERE id IN (SELECT id FROM audit WHERE occurred_at<?1 AND id NOT IN (SELECT audit_id FROM attempts) ORDER BY occurred_at,id LIMIT 256)",[before]))
        })
    }
    pub fn audit_records(&self) -> Result<Vec<AuditRecord>> {
        let c = self.read()?;
        let mut s = sql(c.prepare("SELECT id,occurred_at,kind,payload FROM audit ORDER BY id"))?;
        let rows = sql(s.query_map([], |r| {
            Ok(AuditRecord {
                id: r.get(0)?,
                occurred_at: r.get(1)?,
                kind: r.get(2)?,
                payload: r.get(3)?,
            })
        }))?;
        rows.map(sql).collect()
    }
    pub fn audit_events(&self) -> Result<Vec<AuditEvent>> {
        self.audit_records()?
            .iter()
            .filter_map(|r| r.event().transpose())
            .collect()
    }
    pub fn reclaim_totals(&self) -> Result<ReclaimTotals> {
        sql(self.read()?.query_row("SELECT COALESCE(SUM(items),0),COALESCE(SUM(bytes),0),COALESCE(SUM(known_items),0),MIN(occurred_at),MAX(occurred_at) FROM reclaim",[],totals))
    }
    pub fn reclaim_days(&self, from: f64, until: f64) -> Result<Vec<ReclaimDay>> {
        finite(from)?;
        finite(until)?;
        let c = self.read()?;
        let mut s=sql(c.prepare("SELECT COALESCE(SUM(items),0),COALESCE(SUM(bytes),0),COALESCE(SUM(known_items),0),MIN(occurred_at),MAX(occurred_at),CAST(occurred_at/86400 AS INTEGER)-(occurred_at/86400<CAST(occurred_at/86400 AS INTEGER)) AS day FROM reclaim WHERE occurred_at>=?1 AND occurred_at<?2 GROUP BY day ORDER BY day"))?;
        let rows = sql(s.query_map(params![from, until], |r| {
            Ok(ReclaimDay {
                utc_day: r.get(5)?,
                totals: totals(r)?,
            })
        }))?;
        rows.map(sql).collect()
    }
    pub fn refresh_projects(&mut self) -> Result<()> {
        let projects = {
            let c = self.read()?;
            let mut s =
                sql(c.prepare("SELECT identity,activity FROM projects ORDER BY identity_key"))?;
            let rows = sql(s.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))))?;
            rows.map(|r| {
                let (identity, activity) = sql(r)?;
                Ok(Project {
                    identity: decode::<Identity>(&identity)?.decode()?,
                    activity,
                })
            })
            .collect::<Result<_>>()?
        };
        self.projects = projects;
        Ok(())
    }
    pub fn reconcile_attempts(&mut self, now: f64) -> Result<usize> {
        let pending = self.dangling_attempts()?;
        for identity in &pending {
            self.finish_recovery(
                identity,
                AuditEvent {
                    occurred_at: now,
                    kind: AuditKind::SafetySkipped,
                    identity: Some(identity.clone()),
                    rule_id: None,
                    detail: Some(
                        "Interrupted Trash attempt; outcome unknown; fresh scan required".into(),
                    ),
                    bytes: None,
                    item_count: None,
                },
            )?;
        }
        Ok(pending.len())
    }
}
fn totals(r: &rusqlite::Row<'_>) -> rusqlite::Result<ReclaimTotals> {
    Ok(ReclaimTotals {
        items: r.get(0)?,
        bytes: r.get(1)?,
        known_items: r.get(2)?,
        first_at: r.get(3)?,
        last_at: r.get(4)?,
    })
}
fn strings<P: rusqlite::Params>(c: &Connection, query: &str, p: P) -> Result<Vec<String>> {
    let mut s = sql(c.prepare(query))?;
    let rows = sql(s.query_map(p, |r| r.get(0)))?;
    rows.map(sql).collect()
}
fn stored_root(c: &Connection, path: &str, flavor: PathFlavor) -> Result<String> {
    Ok(strings(c, "SELECT path FROM roots", [])?
        .into_iter()
        .find(|root| same_path(path, root, flavor))
        .unwrap_or_else(|| path.into()))
}
fn replace_roots(tx: &Transaction<'_>, roots: &[String], flavor: PathFlavor) -> Result<()> {
    let old = strings(tx, "SELECT path FROM roots", [])?;
    for path in &old {
        if !roots.iter().any(|root| same_path(path, root, flavor)) {
            sql(tx.execute("DELETE FROM roots WHERE path=?", [path]))?;
        }
    }
    for (position, root) in roots.iter().enumerate() {
        let path = old
            .iter()
            .find(|path| same_path(path, root, flavor))
            .unwrap_or(root);
        sql(tx.execute("INSERT INTO roots VALUES(?1,?2) ON CONFLICT(path) DO UPDATE SET position=excluded.position", params![path, position as i64]))?;
    }
    Ok(())
}
/// Range-bounded variant of `delete_where` for tables with a `path_key` column.
/// Like `delete_where`, but only rows whose `path_key` equals the key of `base` or lies below it are examined
/// (an index range scan); `hit` still decides exactly, so results equal the full scan's.
fn delete_subtree(
    tx: &Transaction<'_>,
    table: &str,
    flavor: PathFlavor,
    base: &str,
    mut hit: impl FnMut(&str, &str) -> bool,
) -> Result<usize> {
    let key = path_key(flavor, base);
    let stem = key.trim_end_matches('/');
    let (prefix, upper) = (format!("{stem}/"), format!("{stem}0"));
    let doomed: Vec<String> = {
        let mut s = sql(tx.prepare_cached(&format!(
            "SELECT identity_key,path_hint FROM {table} WHERE path_key=?1 OR (path_key>=?2 AND path_key<?3)"
        )))?;
        let rows = sql(s.query_map(params![key, prefix, upper], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        }))?;
        let mut doomed = vec![];
        for row in rows {
            let (k, hint) = sql(row)?;
            if hit(&k, &hint) {
                doomed.push(k);
            }
        }
        doomed
    };
    let mut del = sql(tx.prepare_cached(&format!("DELETE FROM {table} WHERE identity_key=?")))?;
    for k in &doomed {
        sql(del.execute([k]))?;
    }
    Ok(doomed.len())
}
/// Flavor-specific comparison key of a path hint (see schema V7). Descendants of `base` have keys in
/// `[stem/, stem0)` where `stem` is `base`'s key without trailing slashes.
fn path_key(flavor: PathFlavor, path: &str) -> String {
    match flavor {
        PathFlavor::Windows => WindowsKey::new(path).as_str().to_owned(),
        PathFlavor::Posix => tinyprune_core::swiftstr::nfc(&flavor.normalize(path)),
    }
}
/// Re-keys every candidate and observation row when the store is opened with a different flavor than the one
/// the keys were computed for, or when rows without a key exist (migration from schema 6).
fn ensure_keys(c: &Connection, flavor: PathFlavor) -> Result<()> {
    let want = i64::from(flavor == PathFlavor::Windows);
    let have: Option<i64> = sql(c
        .query_row("SELECT flavor FROM key_meta WHERE id=1", [], |r| r.get(0))
        .optional())?;
    let unkeyed: bool = sql(c.query_row(
        "SELECT EXISTS(SELECT 1 FROM candidates WHERE path_key='') OR EXISTS(SELECT 1 FROM observations WHERE path_key='')",
        [],
        |r| r.get(0),
    ))?;
    if have == Some(want) && !unkeyed {
        return Ok(());
    }
    let tx = sql(c.unchecked_transaction())?;
    for table in ["candidates", "observations"] {
        let rows: Vec<(String, String)> = {
            let mut s = sql(tx.prepare(&format!("SELECT identity_key,path_hint FROM {table}")))?;
            let rows = sql(s.query_map([], |r| Ok((r.get(0)?, r.get(1)?))))?;
            rows.map(sql).collect::<Result<_>>()?
        };
        let mut up = sql(tx.prepare(&format!(
            "UPDATE {table} SET path_key=?2 WHERE identity_key=?1"
        )))?;
        for (k, hint) in rows {
            sql(up.execute(params![k, path_key(flavor, &hint)]))?;
        }
    }
    sql(tx.execute(
        "INSERT INTO key_meta(id,flavor) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET flavor=excluded.flavor",
        [want],
    ))?;
    sql(tx.commit())
}
/// Deletes rows of a table keyed by `identity_key` with a `path_hint` column, selected by `hit(key, hint)`.
/// Scans only those two columns (covering index for candidates), never decoding payload JSON.
fn delete_where(
    tx: &Transaction<'_>,
    table: &str,
    mut hit: impl FnMut(&str, &str) -> bool,
) -> Result<usize> {
    let doomed: Vec<String> = {
        let mut s = sql(tx.prepare_cached(&format!("SELECT identity_key,path_hint FROM {table}")))?;
        let rows = sql(s.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))))?;
        let mut doomed = vec![];
        for row in rows {
            let (k, hint) = sql(row)?;
            if hit(&k, &hint) {
                doomed.push(k);
            }
        }
        doomed
    };
    let mut del = sql(tx.prepare_cached(&format!("DELETE FROM {table} WHERE identity_key=?")))?;
    for k in &doomed {
        sql(del.execute([k]))?;
    }
    Ok(doomed.len())
}
/// Upserts candidate rows under the longest managed root containing each path. With a `subtree`, a
/// candidate outside it is an error; `seen` collects the identity keys written. Returns changed rows.
fn upsert_candidates_in(
    tx: &Transaction<'_>,
    flavor: PathFlavor,
    candidates: &[RuleCandidate],
    subtree: Option<&Contains<'_>>,
    mut seen: Option<&mut HashSet<String>>,
) -> Result<usize> {
    let mut roots: Vec<(String, usize)> = strings(tx, "SELECT path FROM roots", [])?
        .into_iter()
        .map(|root| {
            let normalized_len = flavor.normalize(&root).len();
            (root, normalized_len)
        })
        .collect();
    roots.sort_by_key(|(_, normalized_len)| std::cmp::Reverse(*normalized_len));
    let scopes: Vec<Contains<'_>> = roots
        .iter()
        .map(|(root, _)| Contains::new(root, flavor))
        .collect();
    let mut changed = 0usize;
    let mut up = sql(tx.prepare_cached(UPSERT_CANDIDATE))?;
    for candidate in candidates {
        let hint = &candidate.identity.path_hint;
        let hint_key = (flavor == PathFlavor::Windows).then(|| WindowsKey::new(hint));
        if subtree.is_some_and(|subtree| !subtree.holds(hint, hint_key.as_ref())) {
            return Err("Candidate outside published subtree".into());
        }
        let root = scopes
            .iter()
            .find(|scope| scope.holds(hint, hint_key.as_ref()))
            .ok_or("Candidate outside managed roots")?
            .root;
        let k = key(&candidate.identity);
        changed += sql(up.execute(params![
            &k,
            root,
            encode(&Candidate::from(candidate))?,
            hint,
            path_key(flavor, hint)
        ]))?;
        if let Some(seen) = seen.as_deref_mut() {
            seen.insert(k);
        }
    }
    Ok(changed)
}
/// Upserts deadline rows (auditing only new or changed ones) and returns their identity keys.
fn upsert_deadlines_in(
    tx: &Transaction<'_>,
    root: &str,
    deadlines: &[TrashRequest],
) -> Result<HashSet<String>> {
    let mut seen = HashSet::with_capacity(deadlines.len());
    let mut up = sql(tx.prepare_cached(UPSERT_DEADLINE))?;
    let mut audit = sql(tx.prepare_cached(INSERT_AUDIT))?;
    for r in deadlines {
        finite(r.scheduled_at)?;
        let k = key(&r.candidate_identity);
        let p = encode(&Request::from(r))?;
        if sql(up.execute(params![&k, root, r.scheduled_at, &p]))? > 0 {
            sql(audit.execute(params![r.scheduled_at, "deadlineScheduled", &p]))?;
        }
        seen.insert(k);
    }
    Ok(seen)
}
fn record(tx: &Transaction<'_>, at: f64, kind: &str, payload: &str) -> Result<i64> {
    finite(at)?;
    sql(tx.execute(INSERT_AUDIT, params![at, kind, payload]))?;
    if matches!(
        kind,
        "ruleMutation"
            | "ruleRemoved"
            | "overrideMutation"
            | "overrideRemoved"
            | "managedRootsMutation"
            | "settingsMutation"
            | "configImported"
    ) {
        sql(tx.execute("UPDATE settings SET revision=revision+1 WHERE id=1", []))?;
    }
    Ok(tx.last_insert_rowid())
}
fn append_event(tx: &Transaction<'_>, e: &AuditEvent, flavor: PathFlavor) -> Result<()> {
    let id = record(
        tx,
        e.occurred_at,
        e.kind.as_str(),
        &encode(&Event::from(e))?,
    )?;
    if let Some(identity) = &e.identity {
        match e.kind {
            AuditKind::TrashAttempted => {
                sql(tx.execute("INSERT INTO attempts VALUES(?1,?2,?3) ON CONFLICT(identity_key) DO UPDATE SET identity=excluded.identity,audit_id=excluded.audit_id",params![key(identity),encode(&Identity::from(identity))?,id]))?;
            }
            AuditKind::MovedToTrash | AuditKind::TrashFailed => {
                sql(tx.execute("DELETE FROM attempts WHERE identity_key=?", [key(identity)]))?;
            }
            _ => {}
        }
    }
    if e.kind == AuditKind::MovedToTrash {
        if let Some(identity) = &e.identity {
            let payload = sql(tx
                .query_row(
                    "SELECT payload FROM deadlines WHERE identity_key=?",
                    [key(identity)],
                    |r| r.get::<_, String>(0),
                )
                .optional())?;
            if let Some(payload) = payload {
                if decode::<Request>(&payload)?.decode()?.candidate_identity == *identity {
                    sql(tx.execute(
                        "DELETE FROM deadlines WHERE identity_key=?",
                        [key(identity)],
                    ))?;
                }
            }
            let moved = key(identity);
            let volume_prefix = format!("{}:", identity.volume);
            // Candidate deletion cascades to current_decisions via trigger; also drop the moved
            // identity's decision explicitly in case no candidate row exists.
            let below = Contains::new(&identity.path_hint, flavor);
            sql(tx.execute("DELETE FROM candidates WHERE identity_key=?", [&moved]))?;
            delete_subtree(tx, "candidates", flavor, &identity.path_hint, |k, hint| {
                k.starts_with(&volume_prefix) && below.strictly_below(hint)
            })?;
            sql(tx.execute(
                "DELETE FROM current_decisions WHERE identity_key=?",
                [&moved],
            ))?;
        }
    }
    if e.kind == AuditKind::MovedToTrash {
        let items = e.item_count.unwrap_or(1).max(1);
        let items = i64::try_from(items).map_err(|_| "Item count overflow")?;
        sql(tx.execute(
            "INSERT INTO reclaim VALUES(?1,?2,?3,?4,?5)",
            params![
                id,
                e.occurred_at,
                items,
                e.bytes.unwrap_or(0).max(0),
                if e.bytes.is_some() { items } else { 0 }
            ],
        ))?;
    }
    Ok(())
}
impl PolicyStore for Store {
    fn load_snapshot(&mut self) -> Result<PolicySnapshot> {
        self.read_transaction(|tx| {
            let rules = strings(tx, "SELECT payload FROM rules ORDER BY position,id", [])?
                .into_iter()
                .map(|p| decode::<Rule>(&p)?.decode())
                .collect::<Result<_>>()?;
            let overrides = strings(tx, "SELECT payload FROM overrides ORDER BY position,id", [])?
                .into_iter()
                .map(|p| decode::<Override>(&p)?.decode())
                .collect::<Result<_>>()?;
            let managed_roots = strings(tx, "SELECT path FROM roots ORDER BY position,path", [])?;
            let (globally_paused, hidden, grace, windows) = sql(tx.query_row(
                "SELECT paused,hidden,grace,windows FROM settings WHERE id=1",
                [],
                |r| {
                    Ok((
                        r.get::<_, bool>(0)?,
                        r.get::<_, bool>(1)?,
                        r.get::<_, f64>(2)?,
                        r.get::<_, bool>(3)?,
                    ))
                },
            ))?;
            Ok(PolicySnapshot {
                rules,
                overrides,
                managed_roots,
                globally_paused,
                settings: AgentSettings {
                    protect_hidden_files: hidden,
                    default_grace_period_seconds: grace,
                    path_flavor: if windows {
                        PathFlavor::Windows
                    } else {
                        PathFlavor::Posix
                    },
                },
            })
        })
    }
}
impl ObservationStore for Store {
    fn observation(&self, i: &FilesystemIdentity) -> Result<Option<Observation>> {
        let row = sql(self
            .read()?
            .query_row(
                "SELECT identity,first,last FROM observations WHERE identity_key=?",
                [key(i)],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, f64>(1)?,
                        r.get::<_, f64>(2)?,
                    ))
                },
            )
            .optional())?;
        row.map(|(p, first, last)| {
            Ok(Observation {
                identity: decode::<Identity>(&p)?.decode()?,
                first,
                last,
            })
        })
        .transpose()
        .map(|o| o.filter(|o| o.identity == *i))
    }
    /// Skips the write transaction entirely when the stored row already equals the merged result.
    fn save_observation(&mut self, o: Observation) -> Result<()> {
        finite(o.first)?;
        finite(o.last)?;
        let identity_json = encode(&Identity::from(&o.identity))?;
        let k = key(&o.identity);
        let committed: Option<(String, f64, f64)> = sql(self
            .read()?
            .query_row(
                "SELECT identity,first,last FROM observations WHERE identity_key=?",
                [&k],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional())?;
        if let Some((json, first, last)) = &committed {
            if *json == identity_json && first.min(o.first) == *first && last.max(o.last) == *last {
                return Ok(());
            }
        }
        self.transaction(|tx| {
            let old=sql(tx.query_row("SELECT identity,first,last FROM observations WHERE identity_key=?",[&k],|r|Ok((r.get::<_,String>(0)?,r.get::<_,f64>(1)?,r.get::<_,f64>(2)?))).optional())?;
            let (first,last)=match old { Some((p,first,last)) if decode::<Identity>(&p)?.decode()?==o.identity=>(first.min(o.first),last.max(o.last)),_=>(o.first,o.last) };
            sql(tx.execute("INSERT INTO observations(identity_key,path_hint,identity,first,last,path_key) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(identity_key) DO UPDATE SET path_hint=excluded.path_hint,path_key=excluded.path_key,identity=excluded.identity,first=excluded.first,last=excluded.last",params![&k,o.identity.path_hint,identity_json,first,last,path_key(self.path_flavor,&o.identity.path_hint)]))?; Ok(())
        })
    }
    fn projects(&self) -> Result<&[Project]> {
        Ok(&self.projects)
    }
    fn publish_projects(&mut self, root: &str, projects: Vec<Project>) -> Result<()> {
        let flavor = self.path_flavor;
        self.transaction(|tx| {
            let old=strings(tx,"SELECT identity FROM projects",[])?;
            let scope = Contains::new(root, flavor);
            let mut kept: std::collections::HashMap<String, Vec<&FilesystemIdentity>> = std::collections::HashMap::new();
            for p in &projects { kept.entry(key(&p.identity)).or_default().push(&p.identity); }
            for p in old { let identity=decode::<Identity>(&p)?.decode()?; let k=key(&identity); if scope.path(&identity.path_hint)&&!kept.get(&k).is_some_and(|same|same.iter().any(|i|**i==identity)) { sql(tx.execute("DELETE FROM projects WHERE identity_key=?",[k]))?; } }
            for p in &projects { finite(p.activity)?; let previous=sql(tx.query_row("SELECT identity,activity FROM projects WHERE identity_key=?",[key(&p.identity)],|r|Ok((r.get::<_,String>(0)?,r.get::<_,f64>(1)?))).optional())?; let activity=match previous { Some((i,a)) if decode::<Identity>(&i)?.decode()?==p.identity=>a.max(p.activity),_=>p.activity }; sql(tx.execute("INSERT INTO projects VALUES(?1,?2,?3,?4) ON CONFLICT(identity_key) DO UPDATE SET path_hint=excluded.path_hint,identity=excluded.identity,activity=excluded.activity",params![key(&p.identity),p.identity.path_hint,encode(&Identity::from(&p.identity))?,activity]))?; }
            Ok(())
        })?;
        self.refresh_projects()
    }
    fn remove_below(&mut self, path: &str) -> Result<()> {
        let flavor = self.path_flavor;
        self.transaction(|tx| {
            let scope = Contains::new(path, flavor);
            delete_where(tx, "projects", |_, hint| scope.path(hint))?;
            for table in ["observations", "candidates"] {
                delete_subtree(tx, table, flavor, path, |_, hint| scope.path(hint))?;
            }
            Ok(())
        })?;
        self.refresh_projects()
    }
}
impl AgentStore for Store {
    fn load_deadlines(&mut self) -> Result<Vec<TrashRequest>> {
        strings(
            &*self.read()?,
            "SELECT payload FROM deadlines ORDER BY scheduled_at,identity_key",
            [],
        )?
        .into_iter()
        .map(|p| decode::<Request>(&p)?.decode())
        .collect()
    }
    /// Set semantics: upserts only new/changed rows and deletes vanished ones. An identical set writes
    /// nothing (no row rewrite, no audit).
    fn replace_deadlines(&mut self, root: &str, deadlines: &[TrashRequest]) -> Result<()> {
        self.transaction(|tx| {
            let root = stored_root(tx, root, self.path_flavor)?;
            let seen = upsert_deadlines_in(tx, &root, deadlines)?;
            let existing = strings(
                tx,
                "SELECT identity_key FROM deadlines WHERE root=?",
                [&root],
            )?;
            let mut del = sql(tx.prepare_cached("DELETE FROM deadlines WHERE identity_key=?"))?;
            for k in existing.iter().filter(|k| !seen.contains(*k)) {
                sql(del.execute([k]))?;
            }
            Ok(())
        })
    }
    /// Incremental form: upserts `deadlines`, then deletes the deadline of every `evaluated` identity
    /// that has none in `deadlines`. Other rows are never read or touched (no scan of the root).
    fn update_deadlines(
        &mut self,
        root: &str,
        evaluated: &[FilesystemIdentity],
        deadlines: &[TrashRequest],
    ) -> Result<()> {
        self.transaction(|tx| {
            let root = stored_root(tx, root, self.path_flavor)?;
            let seen = upsert_deadlines_in(tx, &root, deadlines)?;
            let mut del = sql(tx.prepare_cached("DELETE FROM deadlines WHERE identity_key=?"))?;
            for identity in evaluated {
                let k = key(identity);
                if !seen.contains(&k) {
                    sql(del.execute([&k]))?;
                }
            }
            Ok(())
        })
    }
    fn remove_deadline(&mut self, r: &TrashRequest) -> Result<()> {
        self.transaction(|tx| {
            let p = sql(tx
                .query_row(
                    "SELECT payload FROM deadlines WHERE identity_key=? AND scheduled_at=?",
                    params![key(&r.candidate_identity), r.scheduled_at],
                    |row| row.get::<_, String>(0),
                )
                .optional())?;
            if let Some(p) = p {
                if decode::<Request>(&p)?.decode()?.candidate_identity == r.candidate_identity {
                    sql(tx.execute(
                        "DELETE FROM deadlines WHERE identity_key=? AND scheduled_at=?",
                        params![key(&r.candidate_identity), r.scheduled_at],
                    ))?;
                    record(tx, r.scheduled_at, "deadlineRemoved", &p)?;
                }
            }
            Ok(())
        })
    }
}
impl AuditSink for Store {
    fn append(&mut self, e: AuditEvent) -> Result<()> {
        self.transaction(|tx| append_event(tx, &e, self.path_flavor))
    }
}
impl AgentAudit for Store {
    fn dangling_attempts(&mut self) -> Result<Vec<FilesystemIdentity>> {
        strings(
            &*self.read()?,
            "SELECT identity FROM attempts ORDER BY audit_id",
            [],
        )?
        .into_iter()
        .map(|p| decode::<Identity>(&p)?.decode())
        .collect()
    }
    fn finish_recovery(&mut self, i: &FilesystemIdentity, e: AuditEvent) -> Result<()> {
        if e.kind != AuditKind::SafetySkipped || e.identity.as_ref() != Some(i) {
            return Err(
                "Recovery must record an unknown-outcome safety skip for the same identity".into(),
            );
        }
        self.transaction(|tx| {
            let deleted = sql(tx.execute("DELETE FROM attempts WHERE identity_key=?", [key(i)]))?;
            if deleted > 0 {
                append_event(tx, &e, self.path_flavor)?;
            }
            Ok(())
        })
    }
}
#[cfg(test)]
mod tests;
