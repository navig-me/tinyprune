//! Windows-flavor store scaling with synthetic `C:\Root\DirNNNN\FileNNNNNN.DAT` candidates.
//! Ignored benchmark (file-backed, real fsync):
//!   cargo test --release --locked -p tinyprune-store --test windows_scale -- --ignored --nocapture
use std::time::Instant;
use tinyprune_agent::AgentStore;
use tinyprune_core::{path::PathFlavor, rule::*, trash::*, uuid::Uuid};
use tinyprune_store::{DecisionRow, Store};

fn identity(n: usize, path: String) -> FilesystemIdentity {
    FilesystemIdentity {
        volume: Uuid(1),
        resource: (n as u64).to_be_bytes().to_vec(),
        path_hint: path,
        creation_time: None,
        generation: None,
        is_persistent: false,
    }
}
fn tree(dirs: usize, per: usize) -> Vec<RuleCandidate> {
    let mut all = Vec::with_capacity(dirs * (per + 1));
    for d in 0..dirs {
        let dir = identity(all.len(), format!(r"C:\Root\Dir{d:04}"));
        all.push(RuleCandidate::new(
            dir,
            format!("Dir{d:04}"),
            ItemKind::Directory,
            CandidateTimestamps::default(),
        ));
        for f in 0..per {
            let id = identity(all.len(), format!(r"C:\Root\Dir{d:04}\File{f:06}.DAT"));
            all.push(RuleCandidate::new(
                id,
                format!("File{f:06}.DAT"),
                ItemKind::File,
                CandidateTimestamps {
                    modified: Some(0.0),
                    ..Default::default()
                },
            ));
        }
    }
    all
}
fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

/// Returns (publish, put_decisions, replace_deadlines, republish identical, remove_below) in ms.
fn run(flavor: PathFlavor, total: usize, root: &str) -> [f64; 5] {
    let dir = std::env::temp_dir().join(format!(
        "tpstore-scale-{}-{total}-{flavor:?}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let mut store = Store::open_with_flavor(dir.join("s.sqlite3"), flavor).unwrap();
    store.replace_roots(&[root.into()], 0.0).unwrap();
    let candidates = tree(total / 1000, 1000);
    let start = Instant::now();
    store
        .publish_candidate_subtree(root, &candidates, 1.0)
        .unwrap();
    let publish = ms(start);
    let explanation = serde_json::json!({"x": 1});
    let start = Instant::now();
    for page in candidates.chunks(512) {
        let rows: Vec<DecisionRow<'_>> = page
            .iter()
            .map(|c| DecisionRow {
                identity: &c.identity,
                scheduled_at: Some(10.0),
                rule_id: Some("r"),
                preview: false,
                explanation: &explanation,
            })
            .collect();
        store.put_decisions(2.0, &rows).unwrap();
    }
    let decisions = ms(start);
    let requests: Vec<TrashRequest> = candidates
        .iter()
        .filter(|c| c.kind == ItemKind::File)
        .map(|c| TrashRequest {
            candidate_identity: c.identity.clone(),
            source: ScheduledSource::Rule(Uuid(2)),
            scheduled_at: 5.0,
        })
        .collect();
    let start = Instant::now();
    store.replace_deadlines(root, &requests).unwrap();
    let deadlines = ms(start);
    let start = Instant::now();
    store
        .publish_candidate_subtree(root, &candidates, 3.0)
        .unwrap();
    let republish = ms(start);
    let start = Instant::now();
    tinyprune_core::scheduler::ObservationStore::remove_below(
        &mut store,
        &format!(
            "{root}{}Dir0000",
            if flavor == PathFlavor::Windows {
                "\\"
            } else {
                "/"
            }
        ),
    )
    .unwrap();
    let remove = ms(start);
    drop(store);
    let _ = std::fs::remove_dir_all(dir);
    [publish, decisions, deadlines, republish, remove]
}

#[test]
#[ignore = "benchmark"]
fn bench_store_windows_vs_posix() {
    println!(
        "{:>8} {:>8} {:>10} {:>10} {:>10} {:>10} {:>10}",
        "flavor", "n", "publish", "decisions", "deadlines", "republish", "removeBelow"
    );
    for total in [25_000usize, 50_000, 100_000] {
        for (flavor, root) in [
            (PathFlavor::Windows, r"C:\Root"),
            (PathFlavor::Posix, "/root"),
        ] {
            let t = if flavor == PathFlavor::Posix {
                posix_run(total)
            } else {
                run(flavor, total, root)
            };
            println!(
                "{:>8} {:>8} {:>10.0} {:>10.0} {:>10.0} {:>10.0} {:>10.0}",
                format!("{flavor:?}"),
                total,
                t[0],
                t[1],
                t[2],
                t[3],
                t[4]
            );
        }
    }
}

/// POSIX control: same shape with `/root/dirNNNN/fileNNNNNN.dat` spelling.
fn posix_run(total: usize) -> [f64; 5] {
    let dir = std::env::temp_dir().join(format!(
        "tpstore-scale-{}-{total}-posix",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let mut store = Store::open(dir.join("s.sqlite3")).unwrap();
    store.replace_roots(&["/root".into()], 0.0).unwrap();
    let mut candidates = tree(total / 1000, 1000);
    for c in &mut candidates {
        c.identity.path_hint = c
            .identity
            .path_hint
            .replace(r"C:\Root", "/root")
            .replace('\\', "/");
    }
    let start = Instant::now();
    store
        .publish_candidate_subtree("/root", &candidates, 1.0)
        .unwrap();
    let publish = ms(start);
    let explanation = serde_json::json!({"x": 1});
    let start = Instant::now();
    for page in candidates.chunks(512) {
        let rows: Vec<DecisionRow<'_>> = page
            .iter()
            .map(|c| DecisionRow {
                identity: &c.identity,
                scheduled_at: Some(10.0),
                rule_id: Some("r"),
                preview: false,
                explanation: &explanation,
            })
            .collect();
        store.put_decisions(2.0, &rows).unwrap();
    }
    let decisions = ms(start);
    let requests: Vec<TrashRequest> = candidates
        .iter()
        .filter(|c| c.kind == ItemKind::File)
        .map(|c| TrashRequest {
            candidate_identity: c.identity.clone(),
            source: ScheduledSource::Rule(Uuid(2)),
            scheduled_at: 5.0,
        })
        .collect();
    let start = Instant::now();
    store.replace_deadlines("/root", &requests).unwrap();
    let deadlines = ms(start);
    let start = Instant::now();
    store
        .publish_candidate_subtree("/root", &candidates, 3.0)
        .unwrap();
    let republish = ms(start);
    let start = Instant::now();
    tinyprune_core::scheduler::ObservationStore::remove_below(&mut store, "/root/Dir0000").unwrap();
    let remove = ms(start);
    drop(store);
    let _ = std::fs::remove_dir_all(dir);
    [publish, decisions, deadlines, republish, remove]
}
