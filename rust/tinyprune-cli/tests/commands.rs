use serde::de::DeserializeOwned;
use serde_json::Value;
use std::{
    io,
    sync::{Arc, Mutex},
};
use tinyprune_ipc::*;

fn fixture<T: DeserializeOwned>(name: &str) -> T {
    let all: Value = serde_json::from_str(include_str!("../../../Fixtures/ipc/dtos.json")).unwrap();
    serde_json::from_value(all[name].clone()).unwrap()
}
#[derive(Default)]
struct Fake {
    requests: Mutex<Vec<Request>>,
    failure: Option<ErrorCode>,
}
impl AgentService for Fake {
    fn handle(&self, request: Request) -> Response {
        self.requests.lock().unwrap().push(request.clone());
        if let Some(code) = self.failure {
            return Response::Failure(ServiceError {
                code,
                message: "fixture failure".into(),
            });
        }
        match request {
            Request::Health => Response::Health(fixture("Health")),
            Request::LoadPolicy => Response::Policy(fixture("PolicySnapshot")),
            Request::LoadOverview => Response::Overview(Box::new(fixture("Overview"))),
            Request::LoadSettings => Response::Settings(fixture("Settings")),
            Request::LoadUpcoming { .. } => {
                let mut page: UpcomingPage = fixture("UpcomingPage");
                page.next_cursor = None;
                Response::UpcomingPage(page)
            }
            Request::LoadActivity { .. } => Response::Activity(vec![fixture("ActivityItem")]),
            Request::ExplainItem { .. } => {
                Response::ItemExplanation(Box::new(fixture("ItemExplanation")))
            }
            Request::PreviewRule(_) => Response::RulePreview(fixture("RulePreview")),
            Request::LoadRoots => Response::Roots(vec![fixture("Root")]),
            Request::ExportConfig => Response::Config {
                text: "version: 1\n".into(),
            },
            _ => Response::Acknowledged(fixture("Acknowledgement")),
        }
    }
}
fn invocation(
    command: &str,
    json: bool,
    fake: Arc<Fake>,
    versions: VersionRange,
) -> (i32, String, String) {
    let (client, stream) = loopback::pair();
    let server = Server::new(
        fake,
        ServerOptions {
            versions,
            ..Default::default()
        },
    )
    .unwrap();
    let worker = server.dispatch(stream).unwrap();
    let mut args: Vec<String> = command.split_whitespace().map(str::to_owned).collect();
    if json {
        args.push("--json".into());
    }
    let input = serde_json::to_vec(&fixture::<Rule>("Rule")).unwrap();
    let mut out = Vec::new();
    let mut err = Vec::new();
    let exit = tinyprune_cli::run(
        &args,
        &mut input.as_slice(),
        &mut out,
        &mut err,
        move |_| Ok(Box::new(client)),
    );
    let result = worker.join().unwrap();
    if versions == VersionRange::default() {
        result.unwrap();
    } else {
        assert!(result.is_err());
    }
    (
        exit,
        String::from_utf8(out).unwrap(),
        String::from_utf8(err).unwrap(),
    )
}
#[test]
fn every_command_human_and_json_over_real_protocol() {
    let cases = [
        ("status", "TinyPrune agent available"),
        ("rules", "Temporary files"),
        ("rules list", "Temporary files"),
        ("rules add -", "Saved rule rule"),
        ("rules edit rule -", "Saved rule rule"),
        ("rules remove rule", "Deleted rule rule"),
        ("rules activate rule", "Activated rule rule"),
        (
            "rules preview rule",
            "Nothing was changed or moved to Trash.",
        ),
        ("upcoming", "Scheduled:"),
        ("keep /managed/item --descendants", "Keeping"),
        ("unkeep /managed/item", "now inherits its rule"),
        ("inherit /managed/item", "now inherits its rule"),
        ("expire /managed/item 7d", "expires"),
        ("pause", "TinyPrune is paused"),
        ("pause 1h", "TinyPrune is paused until"),
        ("pause today", "TinyPrune is paused until"),
        ("pause tomorrow", "TinyPrune is paused until"),
        ("resume", "TinyPrune resumed"),
        ("activity", "Identity:"),
        ("explain /managed/item", "Overrides:"),
        ("why /managed/item", "Overrides:"),
        ("roots", "Managed"),
        ("roots list", "Managed"),
        ("roots add root2 /managed Other", "Added managed folder"),
        ("roots remove root", "Removed managed folder"),
        ("config export", "version: 1"),
        ("config import -", "Configuration imported"),
        ("config apply - --active", "Configuration imported"),
        ("doctor", "Indexed items:"),
        ("delete-rule rule", "Deleted rule rule"),
        ("rebuild-index", "Index rebuild requested"),
    ];
    for (command, expected) in cases {
        for json in [false, true] {
            let fake = Arc::new(Fake::default());
            let (exit, out, err) = invocation(command, json, fake.clone(), VersionRange::default());
            assert_eq!(exit, 0, "{command}: {err} {out}");
            assert!(err.is_empty());
            if json {
                let v: Value = serde_json::from_str(&out).unwrap();
                assert_eq!(v["schemaVersion"], 1, "{command}");
                match command {
                    "status" => assert_eq!(v["serviceVersion"], "development"),
                    "rules" | "rules list" => assert_eq!(v["rules"][0]["name"], "Temporary files"),
                    "upcoming" => assert_eq!(
                        v["items"][0],
                        serde_json::to_value(fixture::<Explanation>("Explanation")).unwrap()
                    ),
                    "activity" => assert_eq!(
                        v["events"][0],
                        serde_json::to_value(fixture::<ActivityItem>("ActivityItem")).unwrap()
                    ),
                    "explain /managed/item" | "why /managed/item" => assert_eq!(
                        v["explanation"],
                        serde_json::to_value(fixture::<ItemExplanation>("ItemExplanation"))
                            .unwrap()
                    ),
                    "roots" | "roots list" => assert_eq!(v["roots"][0]["path"], "/managed"),
                    "config export" => assert_eq!(v["config"], "version: 1\n"),
                    "doctor" => assert_eq!(
                        v["overview"],
                        serde_json::to_value(fixture::<Overview>("Overview")).unwrap()
                    ),
                    "rules preview rule" => assert_eq!(
                        v["preview"],
                        serde_json::to_value(fixture::<RulePreview>("RulePreview")).unwrap()
                    ),
                    _ => {
                        assert_eq!(v["status"], "ok", "{command}");
                        assert!(
                            v["summary"].as_str().unwrap().contains(expected),
                            "{command}"
                        );
                    }
                }
            } else {
                assert!(out.contains(expected), "{command}: {out:?}");
            }
            assert!(!fake.requests.lock().unwrap().is_empty());
        }
    }
}
#[test]
fn full_decision_context_is_never_dropped() {
    for command in [
        "upcoming",
        "activity",
        "explain /managed/item",
        "rules preview rule",
        "doctor",
    ] {
        let (_, out, _) = invocation(
            command,
            false,
            Arc::new(Fake::default()),
            VersionRange::default(),
        );
        for field in [
            "Scheduled:",
            "Eligible:",
            "Rule:",
            "Basis:",
            "Basis date:",
            "Project context:",
            "Override:",
            "Suppression:",
            "Disposition:",
            "Globally paused:",
            "Identity:",
        ] {
            assert!(out.contains(field), "{command} missing {field}: {out}");
        }
    }
}
#[test]
fn stable_human_snapshots_and_json_envelopes() {
    let (exit, out, err) = invocation(
        "resume",
        false,
        Arc::new(Fake::default()),
        VersionRange::default(),
    );
    assert_eq!(
        (exit, out.as_str(), err.as_str()),
        (0, "TinyPrune resumed\n", "")
    );
    let (_, out, _) = invocation(
        "config export",
        true,
        Arc::new(Fake::default()),
        VersionRange::default(),
    );
    assert_eq!(
        serde_json::from_str::<Value>(&out).unwrap(),
        serde_json::json!({"schemaVersion":1,"config":"version: 1\n"})
    );
}
#[test]
fn service_exit_codes_and_version_mismatch() {
    for (code, exit) in [
        (ErrorCode::InvalidRequest, 65),
        (ErrorCode::PolicyConflict, 75),
        (ErrorCode::Busy, 75),
        (ErrorCode::StorageUnavailable, 70),
        (ErrorCode::RootUnavailable, 69),
        (ErrorCode::UnsupportedProtocol, 69),
    ] {
        for json in [false, true] {
            let (actual, out, err) = invocation(
                "status",
                json,
                Arc::new(Fake {
                    failure: Some(code),
                    ..Default::default()
                }),
                VersionRange::default(),
            );
            assert_eq!(actual, exit);
            if json {
                assert_eq!(
                    serde_json::from_str::<Value>(&out).unwrap()["exitCode"],
                    exit
                );
            } else {
                assert!(!err.is_empty());
            }
        }
    }
    for json in [false, true] {
        let (exit, out, err) = invocation(
            "status",
            json,
            Arc::new(Fake::default()),
            VersionRange { min: 99, max: 99 },
        );
        assert_eq!(exit, 69);
        assert!(format!("{out}{err}").contains("Protocol mismatch"));
    }
}
#[test]
fn unavailable_and_usage_failures() {
    for json in [false, true] {
        let mut args = vec!["status".into()];
        if json {
            args.push("--json".into());
        }
        let mut out = Vec::new();
        let mut err = Vec::new();
        let exit = tinyprune_cli::run(&args, &mut io::empty(), &mut out, &mut err, |_| {
            Err(io::Error::new(io::ErrorKind::NotFound, "missing socket"))
        });
        assert_eq!(exit, 69);
        if json {
            assert_eq!(
                String::from_utf8(out).unwrap(),
                "{\"schemaVersion\":1,\"status\":\"unavailable\"}\n"
            );
        } else {
            assert!(String::from_utf8(err)
                .unwrap()
                .contains("Start tinyprune-agent"));
        }
    }
    for command in [
        "unknown",
        "status --wat",
        "status extra",
        "rules edit rule",
        "config",
        "keep",
        "resume extra",
    ] {
        let args = command
            .split_whitespace()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let mut out = Vec::new();
        let mut err = Vec::new();
        assert_eq!(
            tinyprune_cli::run(&args, &mut io::empty(), &mut out, &mut err, |_| panic!(
                "usage error must not connect"
            )),
            64,
            "{command}"
        );
    }
}
#[test]
fn mutations_are_forwarded_with_revision_and_preview_is_not_a_save() {
    let fake = Arc::new(Fake::default());
    invocation(
        "rules activate rule",
        false,
        fake.clone(),
        VersionRange::default(),
    );
    assert!(
        matches!(fake.requests.lock().unwrap().last(),Some(Request::SaveRule{rule,revision,..}) if rule.state==RuleState::Active && *revision==fixture::<PolicySnapshot>("PolicySnapshot").revision)
    );
    let fake = Arc::new(Fake::default());
    invocation(
        "rules preview rule",
        false,
        fake.clone(),
        VersionRange::default(),
    );
    assert!(matches!(
        fake.requests.lock().unwrap().last(),
        Some(Request::PreviewRule(_))
    ));
}
#[cfg(unix)]
#[test]
fn real_unix_socket_and_missing_agent() {
    let dir = std::env::temp_dir().join(format!("tp-cli-{}", std::process::id()));
    let endpoint = dir.join("agent.sock");
    let listener = tinyprune_ipc::unix::Listener::bind(&endpoint).unwrap();
    let worker = std::thread::spawn(move || {
        let server = Server::new(Arc::new(Fake::default()), Default::default()).unwrap();
        server
            .dispatch(listener.accept().unwrap())
            .unwrap()
            .join()
            .unwrap()
            .unwrap();
    });
    let args = vec![
        "resume".into(),
        "--socket".into(),
        endpoint.to_str().unwrap().into(),
    ];
    let mut out = Vec::new();
    assert_eq!(
        tinyprune_cli::run(
            &args,
            &mut io::empty(),
            &mut out,
            &mut Vec::new(),
            tinyprune_cli::connect_local
        ),
        0
    );
    assert_eq!(String::from_utf8(out).unwrap(), "TinyPrune resumed\n");
    worker.join().unwrap();
    assert_eq!(
        tinyprune_cli::run(
            &args,
            &mut io::empty(),
            &mut Vec::new(),
            &mut Vec::new(),
            tinyprune_cli::connect_local
        ),
        69
    );
    std::fs::remove_dir(dir).unwrap();
}
#[test]
fn version_flag_needs_no_agent() {
    let args = vec!["--version".to_owned()];
    let mut out = Vec::new();
    let exit = tinyprune_cli::run(&args, &mut io::empty(), &mut out, &mut Vec::new(), |_| {
        panic!("--version must not connect")
    });
    assert_eq!(exit, 0);
    assert_eq!(
        String::from_utf8(out).unwrap(),
        format!("tinyprune {}\n", env!("CARGO_PKG_VERSION"))
    );
}
