//! 100k-entry benchmark of the REAL `tinyprune-agentd` process over real IPC (ignored by default).
//!
//! cargo test --release --locked -p tinyprune-daemon --test bench -- --ignored --nocapture
//!
//! Mirrors Tests/TinyPruneAgentCoreTests/PhaseTwoBenchmarkTests.swift (100 dirs x 1000 empty `.dat` files,
//! Active `*.dat` modified-basis rule with a one-year lifetime) and prints a table that is *compared* with the
//! Swift bounds but never asserted: only functional failures and a 10 minute index timeout fail the test.
//! Env: TINYPRUNE_BENCH_ENTRIES (100000), TINYPRUNE_BENCH_SOAK_SECONDS (10), TINYPRUNE_BENCH_OUT (also append the
//! markdown table to this file, e.g. $GITHUB_STEP_SUMMARY).
use std::{
    fs,
    io::Write as _,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tinyprune_ipc::*;

#[cfg(unix)]
type Stream = std::os::unix::net::UnixStream;
#[cfg(windows)]
type Stream = std::fs::File;

/// Connects and, on Unix, removes the transport's 30 s I/O timeouts so a long agent stall is measured instead of
/// abandoning the connection (abandoned connections have also been seen to make macOS `accept` fail with EINVAL,
/// which terminates the agent: the run loop returns on any accept error).
fn connect_stream(endpoint: &Path) -> std::io::Result<Stream> {
    #[cfg(unix)]
    {
        let stream = unix::connect(endpoint)?;
        stream.set_read_timeout(None)?;
        stream.set_write_timeout(None)?;
        Ok(stream)
    }
    #[cfg(windows)]
    return windows::connect(endpoint.to_str().unwrap());
}

fn client(endpoint: &Path) -> Client<Stream> {
    let deadline = Instant::now() + Duration::from_secs(600);
    loop {
        match connect_stream(endpoint)
            .and_then(|s| Client::connect(s, VersionRange::default(), 8 * 1024 * 1024))
        {
            Ok(c) => return c,
            Err(e) if Instant::now() < deadline => {
                let _ = e;
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => panic!("agent never became reachable: {e}"),
        }
    }
}

static ENDPOINT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
/// Longest single IPC stall observed (ms): requests that exceeded the transport's 30 s timeout count 30000+.
static MAX_STALL_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Read-only requests are retried on a fresh connection when the agent does not answer within the IPC timeout
/// (the agent serializes requests with its tick, so a long scan can stall them). Mutations are never retried.
fn call(c: &mut Client<Stream>, r: Request) -> Response {
    let readonly = matches!(
        r,
        Request::LoadOverview
            | Request::LoadPolicy
            | Request::LoadUpcoming { .. }
            | Request::ExplainItem { .. }
    );
    let started = Instant::now();
    let outcome = loop {
        match c.request(r.clone()) {
            Ok(response) => break response,
            Err(e) if readonly && started.elapsed() < Duration::from_secs(600) => {
                let _ = e;
                *c = client(ENDPOINT.get().expect("endpoint"));
            }
            Err(e) => panic!(
                "ipc request failed after {:.1}s: {e}",
                started.elapsed().as_secs_f64()
            ),
        }
    };
    MAX_STALL_MS.fetch_max(
        started.elapsed().as_millis() as u64,
        std::sync::atomic::Ordering::Relaxed,
    );
    match outcome {
        Response::Failure(e) => panic!("agent error: {e:?}"),
        other => other,
    }
}

fn timed<T>(f: impl FnOnce() -> T) -> (T, f64) {
    let start = Instant::now();
    let value = f();
    (value, start.elapsed().as_secs_f64() * 1000.0)
}

fn rss_mib(pid: u32) -> f64 {
    #[cfg(windows)]
    let text = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            &format!("(Get-Process -Id {pid}).WorkingSet64 / 1024"),
        ])
        .output();
    #[cfg(unix)]
    let text = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output();
    let text = String::from_utf8(text.expect("rss helper").stdout).unwrap();
    text.trim().parse::<f64>().unwrap_or(f64::NAN) / 1024.0 // KiB -> MiB
}

/// Total process CPU seconds, or None where there is no cheap std-free source.
fn cpu_seconds(pid: u32) -> Option<f64> {
    #[cfg(target_os = "linux")]
    {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let fields: Vec<&str> = stat.rsplit_once(')')?.1.split_whitespace().collect();
        // After the command: state is index 0, utime 11, stime 12 (clock ticks, 100 Hz on Linux).
        let ticks = fields.get(11)?.parse::<f64>().ok()? + fields.get(12)?.parse::<f64>().ok()?;
        Some(ticks / 100.0)
    }
    #[cfg(target_os = "macos")]
    {
        let out = Command::new("ps")
            .args(["-o", "time=", "-p", &pid.to_string()])
            .output()
            .ok()?;
        let text = String::from_utf8(out.stdout).ok()?;
        let (minutes, seconds) = text.trim().split_once(':')?; // M:SS.hh
        Some(minutes.parse::<f64>().ok()? * 60.0 + seconds.parse::<f64>().ok()?)
    }
    #[cfg(windows)]
    {
        let out = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!("(Get-Process -Id {pid}).TotalProcessorTime.TotalSeconds"),
            ])
            .output()
            .ok()?;
        String::from_utf8(out.stdout)
            .ok()?
            .trim()
            .parse::<f64>()
            .ok()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        let _ = pid;
        None
    }
}

/// Waits until the agent used under 50 ms of CPU in each of three consecutive 500 ms intervals (at most 120 s).
/// Without a CPU source it waits a fixed 8 s.
fn wait_until_idle(pid: u32) {
    let Some(mut last) = cpu_seconds(pid) else {
        std::thread::sleep(Duration::from_secs(8));
        return;
    };
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut quiet = 0;
    while quiet < 3 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(500));
        let Some(now) = cpu_seconds(pid) else { return };
        quiet = if now - last < 0.05 { quiet + 1 } else { 0 };
        last = now;
    }
}

fn epoch_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64() * 1000.0)
}

/// One finished daemon phase, from the JSON lines of `TINYPRUNE_PHASE_LOG` (see `tinyprune-daemon/src/phases.rs`).
struct PhaseRecord {
    phase: String,
    ms: f64,
    items: u64,
    end_ms: f64,
}

fn read_phases(path: &Path) -> Vec<PhaseRecord> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let v: serde_json::Value = serde_json::from_str(line).ok()?;
            Some(PhaseRecord {
                phase: v["phase"].as_str()?.to_owned(),
                ms: v["ms"].as_f64()?,
                items: v["items"].as_u64()?,
                end_ms: v["end_ms"].as_f64()?,
            })
        })
        .collect()
}

/// Per-phase totals in order of first appearance; `origin_ms` is the wall-clock zero of the "ended at" column.
fn phase_table(title: &str, records: &[PhaseRecord], origin_ms: f64) -> String {
    let mut out = format!("### {title}\n\n");
    if records.is_empty() {
        return out + "no phase records were written\n\n";
    }
    out += "| Phase | passes | total | longest pass | items (all passes) | first pass ended at |\n|---|---|---|---|---|---|\n";
    let mut names: Vec<&str> = Vec::new();
    for r in records {
        if !names.contains(&r.phase.as_str()) {
            names.push(&r.phase);
        }
    }
    for name in names {
        let mine: Vec<&PhaseRecord> = records.iter().filter(|r| r.phase == name).collect();
        let total: f64 = mine.iter().map(|r| r.ms).sum();
        let longest = mine.iter().map(|r| r.ms).fold(0.0, f64::max);
        let items: u64 = mine.iter().map(|r| r.items).sum();
        out += &format!(
            "| {name} | {} | {:.2} s | {:.2} s | {items} | +{:.1} s |\n",
            mine.len(),
            total / 1000.0,
            longest / 1000.0,
            (mine[0].end_ms - origin_ms) / 1000.0
        );
    }
    out + "\n"
}

/// CPU idleness is insufficient on a runner blocked in SQLite COMMIT. Wait for the explicit
/// completion of the latest full decision job as well, without confusing persisted rows with a
/// completed startup evaluation. Returns false rather than silently labeling a busy run settled.
fn wait_for_decision_settle(path: &Path) -> bool {
    let deadline = Instant::now() + Duration::from_secs(600);
    loop {
        let records = read_phases(path);
        let last_start = records
            .iter()
            .rposition(|r| r.phase == "decision_job_start");
        if last_start.is_some_and(|start| {
            records[start + 1..]
                .iter()
                .any(|r| r.phase == "decision_job_complete")
        }) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Intersect phase spans with the actual event wait. Nested phases overlap; these are diagnostics,
/// not additive buckets. Negative start offsets show work that was already running at file creation.
fn event_phase_table(records: &[PhaseRecord], created_ms: f64, observed_ms: f64) -> String {
    let mut out = String::from("### Event wait trace (relative to file creation)\n\n| Phase | passes | time intersecting wait | first start | last end | items |\n|---|---|---|---|---|---|\n");
    let relevant: Vec<&PhaseRecord> = records
        .iter()
        .filter(|r| r.end_ms >= created_ms && r.end_ms - r.ms <= observed_ms)
        .collect();
    let mut names: Vec<&str> = Vec::new();
    for r in &relevant {
        if !names.contains(&r.phase.as_str()) {
            names.push(&r.phase);
        }
    }
    for name in names {
        let mine: Vec<_> = relevant.iter().filter(|r| r.phase == name).collect();
        let overlap: f64 = mine
            .iter()
            .map(|r| (r.end_ms.min(observed_ms) - (r.end_ms - r.ms).max(created_ms)).max(0.0))
            .sum();
        let first = mine
            .iter()
            .map(|r| r.end_ms - r.ms)
            .fold(f64::INFINITY, f64::min);
        let last = mine.iter().map(|r| r.end_ms).fold(0.0, f64::max);
        let items: u64 = mine.iter().map(|r| r.items).sum();
        out += &format!(
            "| {name} | {} | {overlap:.1} ms | {:+.1} ms | {:+.1} ms | {items} |\n",
            mine.len(),
            first - created_ms,
            last - created_ms
        );
    }
    out + "\nNested SQL/commit, deadline and evaluation spans overlap and must not be summed. Watcher receipt is when the application observes a completed kernel buffer, not the kernel's event timestamp. Zero-duration markers locate receipt, enqueue, overflow/rescan and job boundaries. The final IPC response includes polling/transport delay beyond the deadline commit.\n\n"
}

#[test]
fn event_trace_clips_nested_spans_without_including_unrelated_work() {
    let record = |phase: &str, ms, end_ms| PhaseRecord {
        phase: phase.into(),
        ms,
        end_ms,
        items: 1,
    };
    let table = event_phase_table(
        &[
            record("before", 5.0, 90.0),
            record("queued_work", 30.0, 110.0),
            record("receipt", 0.0, 105.0),
            record("commit", 10.0, 115.0),
            record("after", 5.0, 130.0),
        ],
        100.0,
        120.0,
    );
    assert!(!table.contains("| before |"));
    assert!(!table.contains("| after |"));
    assert!(table.contains("| queued_work | 1 | 10.0 ms | -20.0 ms | +10.0 ms |"));
    assert!(table.contains("| receipt | 1 | 0.0 ms | +5.0 ms | +5.0 ms |"));
    assert!(table.contains("| commit | 1 | 10.0 ms | +5.0 ms | +15.0 ms |"));
}

fn make_fixture(root: &Path, files: usize) -> usize {
    let dirs = files.div_ceil(1000).max(1);
    let per = files.div_ceil(dirs);
    for d in 0..dirs {
        let dir = root.join(format!("group-{d:04}"));
        fs::create_dir_all(&dir).unwrap();
        for f in d * per..((d + 1) * per).min(files) {
            fs::File::create(dir.join(format!("item-{f:06}.dat"))).unwrap();
        }
    }
    dirs
}

struct Agent {
    child: Child,
}
impl Agent {
    fn start(base: &Path, endpoint: &Path, reconcile: u64) -> Agent {
        let child = Command::new(env!("CARGO_BIN_EXE_tinyprune-agentd"))
            .arg("--data-dir")
            .arg(base.join("data"))
            .arg("--endpoint")
            .arg(endpoint)
            .arg("--reconcile-seconds")
            .arg(reconcile.to_string())
            .env(
                "TINYPRUNE_PHASE_LOG",
                base.join(format!("phases-{reconcile}.jsonl")),
            )
            .env("XDG_DATA_HOME", base.join("xdg"))
            .env("HOME", base.join("home"))
            .env("USERPROFILE", base.join("home"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn tinyprune-agentd");
        Agent { child }
    }
    fn pid(&self) -> u32 {
        self.child.id()
    }
}
impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn upcoming_total(c: &mut Client<Stream>, limit: u32) -> u64 {
    match call(
        c,
        Request::LoadUpcoming {
            rule_id: None,
            disposition: None,
            after: None,
            limit,
        },
    ) {
        Response::UpcomingPage(p) => p.total_count,
        other => panic!("unexpected {other:?}"),
    }
}

fn indexed(c: &mut Client<Stream>) -> u64 {
    match call(c, Request::LoadOverview) {
        Response::Overview(o) => o.indexed_items,
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
#[ignore = "100k-entry benchmark; run explicitly with --ignored in release mode"]
fn bench_100k_index_memory_latency_ipc() {
    let files: usize = std::env::var("TINYPRUNE_BENCH_ENTRIES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(100_000);
    let soak: u64 = std::env::var("TINYPRUNE_BENCH_SOAK_SECONDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(10);
    let base = fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(format!("tpbench-{}", std::process::id()));
    let root = base.join("root");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(base.join("home")).unwrap();
    fs::create_dir_all(base.join("xdg")).unwrap();
    #[cfg(unix)]
    let endpoint: PathBuf = base.join("agent.sock");
    #[cfg(windows)]
    let endpoint: PathBuf = format!(r"\\.\pipe\tinyprune-bench-{}", std::process::id()).into();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(base.clone());
    ENDPOINT
        .set(endpoint.clone())
        .expect("single benchmark per process");

    let (dirs, fixture_ms) = timed(|| make_fixture(&root, files));
    let expected_entries = (files + dirs) as u64;

    // ---- phase 1: index, steady state, IPC (reconcile effectively off) ------------------------
    let agent = Agent::start(&base, &endpoint, 3600);
    let mut c = client(&endpoint);
    let rss_start = rss_mib(agent.pid());
    let revision = match call(&mut c, Request::LoadPolicy) {
        Response::Policy(p) => p.revision,
        other => panic!("unexpected {other:?}"),
    };
    let rule = Rule {
        id: "22222222-2222-4222-8222-222222222222".into(),
        name: "Benchmark".into(),
        scope: Scope {
            path: root.to_str().unwrap().into(),
            recursive: true,
        },
        matcher: Matcher {
            item_kind: ItemKind::File,
            exact_names: vec![],
            glob_patterns: vec!["**/*.dat".into()],
        },
        expiry_basis: ExpiryBasis::Modified,
        lifetime: 365.0 * 86400.0,
        grace_period: None,
        action: FolderAction::TrashItem,
        state: RuleState::Active,
        match_mode: MatchMode::Scoped,
    };
    let start_epoch_ms = epoch_ms();
    let start = Instant::now();
    call(
        &mut c,
        Request::SaveRule {
            rule,
            roots: Some(vec![Root {
                id: "33333333-3333-4333-8333-333333333333".into(),
                path: root.to_str().unwrap().into(),
                name: "bench".into(),
            }]),
            keep_paths: vec![],
            unkeep_paths: vec![],
            revision,
        },
    );
    let limit = Duration::from_secs(600);
    let mut index_secs = f64::NAN;
    let mut first_decision_secs = f64::NAN;
    let cpu_start = cpu_seconds(agent.pid());
    let mut cpu_at_index = None;
    loop {
        if index_secs.is_nan() && indexed(&mut c) >= expected_entries {
            index_secs = start.elapsed().as_secs_f64();
            cpu_at_index = cpu_seconds(agent.pid());
        }
        let decisions = if index_secs.is_nan() {
            0
        } else {
            upcoming_total(&mut c, 1)
        };
        if first_decision_secs.is_nan() && decisions > 0 {
            first_decision_secs = start.elapsed().as_secs_f64();
        }
        if decisions >= files as u64 {
            break;
        }
        if start.elapsed() >= limit {
            // Show where the time went before failing: the phase log is the only evidence of a stuck run.
            eprintln!(
                "index {index_secs} s, first decision {first_decision_secs} s, {decisions} of {files} decisions\n{}",
                phase_table(
                    "Phase timing at timeout",
                    &read_phases(&base.join("phases-3600.jsonl")),
                    start_epoch_ms
                )
            );
            panic!("index did not complete in {limit:?}");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let deadlines_secs = start.elapsed().as_secs_f64();
    let cpu_at_done = cpu_seconds(agent.pid());
    let rss_peak_like = rss_mib(agent.pid());

    // idle soak: RSS and CPU
    let cpu0 = cpu_seconds(agent.pid());
    std::thread::sleep(Duration::from_secs(soak));
    let cpu1 = cpu_seconds(agent.pid());
    let rss_idle = rss_mib(agent.pid());
    let idle_cpu = cpu0.zip(cpu1).map(|(a, b)| (b - a).max(0.0));

    // IPC answers (median of 5 after one warm-up)
    let median = |mut v: Vec<f64>| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[v.len() / 2]
    };
    let mut measure = |what: &str, req: &dyn Fn() -> Request| {
        let _ = call(&mut c, req());
        let samples: Vec<f64> = (0..5).map(|_| timed(|| call(&mut c, req())).1).collect();
        eprintln!("  ipc {what}: {samples:?}");
        median(samples)
    };
    let overview_ms = measure("LoadOverview", &|| Request::LoadOverview);
    let upcoming_ms = measure("LoadUpcoming(limit 100)", &|| Request::LoadUpcoming {
        rule_id: None,
        disposition: None,
        after: None,
        limit: 100,
    });
    let sample = root.join("group-0000").join("item-000000.dat");
    let explain_ms = measure("ExplainItem", &|| Request::ExplainItem {
        path: sample.to_str().unwrap().into(),
    });
    drop(c);
    drop(agent);
    let _ = fs::remove_file(&endpoint);

    // ---- phase 2: restart on the persisted index + event-to-deadline latency ---------------------
    // Reconcile is 2 s here because macOS has no native watcher (periodic reconcile fallback, see the daemon
    // README); on Linux/Windows the native watcher delivers the event and the interval is not the limiting factor.
    let phase2_epoch_ms = epoch_ms();
    let agent = Agent::start(&base, &endpoint, 2);
    let restart = Instant::now();
    let mut c = client(&endpoint);
    while upcoming_total(&mut c, 1) < files as u64 {
        assert!(
            restart.elapsed() < limit,
            "restarted agent never re-served the persisted index"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let restart_ready_secs = restart.elapsed().as_secs_f64();
    // A low CPU sample can mean an outstanding Windows fsync, not a settled startup job.
    let settle_start = Instant::now();
    wait_until_idle(agent.pid());
    let phase2_path = base.join("phases-2.jsonl");
    let settled = wait_for_decision_settle(&phase2_path);
    assert!(
        settled,
        "startup decision job did not settle in 600 s\n{}",
        phase_table("Unsettled startup", &read_phases(&phase2_path), phase2_epoch_ms)
    );
    let settle_secs = settle_start.elapsed().as_secs_f64();
    let before = upcoming_total(&mut c, 1);
    let event_epoch_ms = epoch_ms();
    let event = Instant::now();
    fs::File::create(root.join("group-0000").join("event-new.dat")).unwrap();
    let mut latency_ms = f64::NAN;
    while event.elapsed() < Duration::from_secs(120) {
        if upcoming_total(&mut c, 1) > before {
            latency_ms = event.elapsed().as_secs_f64() * 1000.0;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let event_observed_epoch_ms = epoch_ms();
    let rss_phase2 = rss_mib(agent.pid());
    drop(c);
    drop(agent);

    // ---- report ---------------------------------------------------------------------------------
    let os = std::env::consts::OS;
    let watcher = if cfg!(target_os = "macos") {
        "periodic reconcile (2 s) fallback"
    } else {
        "native watcher"
    };
    let verdict = |ok: bool| if ok { "within" } else { "OVER" };
    let mut table = String::new();
    table +=
        &format!("### Rust daemon 100k benchmark ({os}, {files} files, {dirs} dirs; release)\n\n");
    table +=
        "| Metric | Rust | Swift bound (PhaseTwoBenchmarkTests) | vs bound |\n|---|---|---|---|\n";
    table += &format!(
        "| fixture creation | {:.1} s | n/a | n/a |\n",
        fixture_ms / 1000.0
    );
    table += &format!(
        "| initial index ({expected_entries} entries) | {index_secs:.2} s | <= 300 s | {} |\n",
        verdict(index_secs <= 300.0)
    );
    table += &format!("| index + deadlines for all files | {deadlines_secs:.2} s | n/a | n/a |\n");
    table += &format!("| RSS at start / after index / after {soak} s idle | {rss_start:.0} / {rss_peak_like:.0} / {rss_idle:.0} MiB | peak <= 512 MiB | {} |\n", verdict(rss_peak_like.max(rss_idle) <= 512.0));
    table += &match idle_cpu {
        Some(cpu) => format!(
            "| idle CPU over {soak} s | {cpu:.2} s | <= 0.5 s over 60 s | {} (shorter window) |\n",
            verdict(cpu <= 0.5)
        ),
        None => "| idle CPU | not measured on this OS | <= 0.5 s over 60 s | n/a |\n".into(),
    };
    table +=
        &format!("| restart to persisted index served | {restart_ready_secs:.2} s | n/a | n/a |\n");
    table += &format!("| restart startup decision settle wait | {settle_secs:.2} s | n/a | n/a |\n");
    table +=
        &format!("| event-to-deadline latency ({watcher}) | {latency_ms:.0} ms | n/a | n/a |\n");
    table += &format!("| RSS during phase 2 (restart + 2 s reconcile) | {rss_phase2:.0} MiB | peak <= 512 MiB | {} |\n", verdict(rss_phase2 <= 512.0));
    table += &format!("| IPC LoadOverview | {overview_ms:.1} ms | n/a | n/a |\n");
    table += &format!("| IPC LoadUpcoming (100 items) | {upcoming_ms:.1} ms | n/a | n/a |\n");
    table += &format!("| IPC ExplainItem | {explain_ms:.1} ms | n/a | n/a |\n");
    let stall = MAX_STALL_MS.load(std::sync::atomic::Ordering::Relaxed) as f64 / 1000.0;
    table += &format!("| longest IPC stall (any request, during 100k scan/reconcile) | {stall:.1} s | n/a | n/a |\n");
    table += "\nThe event-to-deadline row retains its historical name but measures visibility in `LoadUpcoming` (the current decision table), not only the scheduler deadline write. The event trace separates the deadline transaction from later decision publication and IPC polling. Startup settle is measured separately, using explicit full-decision job completion rather than CPU idleness alone.\n";
    let cpu_note = |a: Option<f64>, b: Option<f64>| match a.zip(b) {
        Some((a, b)) => format!("{:.1} s", (b - a).max(0.0)),
        None => "not measured".into(),
    };
    let mut milestones = String::from("### Rust daemon milestones, first index (seconds after SaveRule)\n\n| Milestone | Value |\n|---|---|\n");
    milestones += &format!("| all {expected_entries} candidates published | {index_secs:.2} s |\n");
    milestones += &format!("| first current decision visible | {first_decision_secs:.2} s |\n");
    milestones += &format!("| all {files} decisions visible | {deadlines_secs:.2} s |\n");
    milestones += &format!(
        "| agent CPU until candidates published | {} |\n",
        cpu_note(cpu_start, cpu_at_index)
    );
    milestones += &format!(
        "| agent CPU from published to all decisions | {} |\n",
        cpu_note(cpu_at_index, cpu_at_done)
    );
    milestones += "\nPhases: enumerate = filesystem metadata traversal; publish = candidate rows to SQLite; record = change fingerprints; evaluate = agent snapshot merge + hydration + rule evaluation (scheduler scan) up to the deadline write; deadlines = deadline rows to SQLite; explain = per-item hydration + resolution + explanation; decisions_store = decision rows to SQLite.\n";
    let phase2_records = read_phases(&phase2_path);
    let phase_report = format!(
        "{}{}{}",
        phase_table(
            "Rust daemon phase timing, first index of the rule (phase 1; passes after the first mean repeated full evaluations)",
            &read_phases(&base.join("phases-3600.jsonl")),
            start_epoch_ms
        ),
        phase_table(
            "Rust daemon phase timing, restart + 2 s reconcile + one new file (phase 2, since agent start)",
            &phase2_records,
            phase2_epoch_ms
        ),
        event_phase_table(&phase2_records, event_epoch_ms, event_observed_epoch_ms)
    );
    println!("\n{table}\n{milestones}\n{phase_report}");
    if let Some(path) = std::env::var_os("TINYPRUNE_BENCH_OUT") {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        writeln!(f, "{table}\n{milestones}\n{phase_report}").unwrap();
    }
    assert!(
        !latency_ms.is_nan(),
        "new file never produced a deadline within 120 s"
    );
}
