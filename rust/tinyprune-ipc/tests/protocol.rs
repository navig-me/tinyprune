use std::{
    io::{self, Cursor, Read},
    sync::{Arc, Barrier},
    thread,
};
use tinyprune_ipc::*;
struct Echo;
impl AgentService for Echo {
    fn handle(&self, request: Request) -> Response {
        match request {
            Request::Health => Response::Health(Health {
                protocol_version: 1,
                service_version: "test".into(),
            }),
            _ => Response::Acknowledged(Acknowledgement {
                revision: 42,
                audit_event_ids: vec!["audit".into()],
            }),
        }
    }
}
fn server(max_connections: usize) -> Server {
    Server::new(
        Arc::new(Echo),
        ServerOptions {
            max_connections,
            ..ServerOptions::default()
        },
    )
    .unwrap()
}
#[test]
fn negotiation_and_mismatch() {
    assert_eq!(
        VersionRange { min: 1, max: 4 }.negotiate(VersionRange { min: 2, max: 3 }),
        Some(3)
    );
    assert_eq!(
        VersionRange { min: 4, max: 2 }.negotiate(VersionRange::default()),
        None
    );
    for (range, succeeds) in [
        (VersionRange::default(), true),
        (VersionRange { min: 2, max: 3 }, false),
    ] {
        let (a, b) = loopback::pair();
        let worker = server(1).dispatch(b).unwrap();
        let client = Client::connect(a, range, 4096);
        assert_eq!(client.is_ok(), succeeds);
        drop(client);
        assert_eq!(worker.join().unwrap().is_ok(), succeeds);
    }
}
#[test]
fn loopback_end_to_end() {
    let (a, b) = loopback::pair();
    let worker = server(1).dispatch(b).unwrap();
    let mut client = Client::connect(a, VersionRange::default(), 4096).unwrap();
    assert!(matches!(
        client.request(Request::Health).unwrap(),
        Response::Health(_)
    ));
    assert!(matches!(
        client.request(Request::RebuildIndex).unwrap(),
        Response::Acknowledged(_)
    ));
    drop(client);
    worker.join().unwrap().unwrap();
}
struct HeaderOnly {
    header: Cursor<[u8; 4]>,
}
impl Read for HeaderOnly {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        assert!(
            self.header.position() < 4,
            "oversized payload must never be read"
        );
        self.header.read(bytes)
    }
}
#[test]
fn framing_limits_and_truncation() {
    let mut input = HeaderOnly {
        header: Cursor::new(u32::MAX.to_be_bytes()),
    };
    assert!(read_frame::<Request>(&mut input, 128).is_err());
    assert!(read_frame::<Request>(&mut Cursor::new([0, 0, 0, 0]), 128).is_err());
    assert!(read_frame::<Request>(&mut Cursor::new([0, 0, 0, 8, b'{']), 128).is_err());
    let mut output = Vec::new();
    assert!(write_frame(&mut output, &"large payload", 2).is_err());
    assert!(
        output.is_empty(),
        "oversize writes must not partially emit a frame"
    );
    write_frame(&mut output, &Request::Health, 1024).unwrap();
    let n = output.len() - 4;
    assert_eq!(
        read_frame::<Request>(&mut Cursor::new(output.clone()), n).unwrap(),
        Request::Health
    );
    assert!(read_frame::<Request>(&mut Cursor::new(output), n - 1).is_err());
}
#[test]
fn evolution_tolerates_unknown_fields_and_variants() {
    assert_eq!(
        serde_json::from_str::<RootState>("\"futureState\"").unwrap(),
        RootState::Unknown
    );
    assert_eq!(
        serde_json::from_str::<OverridePolicy>(r#"{"type":"futurePolicy","payload":{"new":true}}"#)
            .unwrap(),
        OverridePolicy::Unknown
    );
    assert_eq!(
        serde_json::from_str::<Request>(
            r#"{"operation":"futureOperation","arguments":{"new":true}}"#
        )
        .unwrap(),
        Request::Unknown
    );
    assert_eq!(
        serde_json::from_str::<Response>(r#"{"type":"futureReply","data":{"new":true}}"#).unwrap(),
        Response::Unknown
    );
    assert!(serde_json::from_str::<Request>(
        r#"{"operation":"loadUpcoming","arguments":{"limit":"wrong"}}"#
    )
    .is_err());
    assert!(serde_json::from_str::<Response>(r#"{"type":"health","data":{}}"#).is_err());
    assert_eq!(
        serde_json::from_str::<Health>(
            r#"{"protocolVersion":1,"serviceVersion":"test","future":42}"#
        )
        .unwrap()
        .service_version,
        "test"
    );
    let (a, b) = loopback::pair();
    let worker = server(1).dispatch(b).unwrap();
    let mut client = Client::connect(a, VersionRange::default(), 4096).unwrap();
    assert!(matches!(
        client.request(Request::Unknown).unwrap(),
        Response::Failure(ServiceError {
            code: ErrorCode::InvalidRequest,
            ..
        })
    ));
    drop(client);
    worker.join().unwrap().unwrap();
}
#[test]
fn server_rejects_version_drift_and_oversized_request() {
    use std::io::Write;
    let (mut a, b) = loopback::pair();
    let worker = Server::new(
        Arc::new(Echo),
        ServerOptions {
            max_frame: 1024,
            ..ServerOptions::default()
        },
    )
    .unwrap()
    .dispatch(b)
    .unwrap();
    write_frame(
        &mut a,
        &Handshake {
            protocol_version: 1,
            versions: VersionRange::default(),
        },
        1024,
    )
    .unwrap();
    let hello: HandshakeReply = read_frame(&mut a, 1024).unwrap();
    assert_eq!(hello.protocol_version, Some(1));
    write_frame(
        &mut a,
        &RequestEnvelope {
            protocol_version: 2,
            request: Request::Health,
        },
        1024,
    )
    .unwrap();
    let reply: ResponseEnvelope = read_frame(&mut a, 1024).unwrap();
    assert!(matches!(
        reply.response,
        Response::Failure(ServiceError {
            code: ErrorCode::UnsupportedProtocol,
            ..
        })
    ));
    a.write_all(&1025u32.to_be_bytes()).unwrap();
    assert_eq!(
        worker.join().unwrap().unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
}
#[test]
fn concurrent_clients_and_bounded_workers() {
    let server = server(4);
    let barrier = Arc::new(Barrier::new(5));
    let mut workers = Vec::new();
    let mut clients = Vec::new();
    for _ in 0..4 {
        let (a, b) = loopback::pair();
        workers.push(server.dispatch(b).unwrap());
        let barrier = barrier.clone();
        clients.push(thread::spawn(move || {
            let mut client = Client::connect(a, VersionRange::default(), 4096).unwrap();
            barrier.wait();
            assert!(matches!(
                client.request(Request::Health).unwrap(),
                Response::Health(_)
            ));
        }));
    }
    let (_a, b) = loopback::pair();
    assert_eq!(
        server.dispatch(b).unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    barrier.wait();
    for client in clients {
        client.join().unwrap();
    }
    for worker in workers {
        worker.join().unwrap().unwrap();
    }
}
#[cfg(unix)]
#[test]
fn unix_socket_end_to_end_and_peer_rejection() {
    use std::os::unix::fs::PermissionsExt;
    let directory = std::env::temp_dir().join(format!("tinyprune-ipc-{}", std::process::id()));
    let path = directory.join("agent.sock");
    let listener = unix::Listener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    listener.set_nonblocking(false).unwrap();
    assert_eq!(
        std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let join = thread::spawn(move || {
        let stream = listener.accept().unwrap();
        assert!(unix::verify_peer(&stream, unix::current_uid().wrapping_add(1)).is_err());
        server(1).dispatch(stream).unwrap().join().unwrap().unwrap();
    });
    let mut client =
        Client::connect(unix::connect(&path).unwrap(), VersionRange::default(), 4096).unwrap();
    assert!(matches!(
        client.request(Request::Health).unwrap(),
        Response::Health(_)
    ));
    drop(client);
    join.join().unwrap();
    std::fs::remove_dir(directory).unwrap();
}
#[test]
fn golden_dtos_roundtrip() {
    let samples: serde_json::Value =
        serde_json::from_str(include_str!("../../../Fixtures/ipc/dtos.json")).unwrap();
    macro_rules! check { ($($ty:ident),* $(,)?) => { $(
        let value = samples.get(stringify!($ty)).unwrap().clone();
        let parsed: $ty = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(parsed).unwrap(), value, "{}", stringify!($ty));
    )* }; }
    check!(
        VersionRange,
        Handshake,
        HandshakeReply,
        Identity,
        Scope,
        Matcher,
        Rule,
        OverridePolicy,
        ItemOverride,
        OverrideChange,
        Root,
        RootStatus,
        Settings,
        PolicySnapshot,
        ProjectContext,
        Explanation,
        UpcomingItem,
        UpcomingCursor,
        UpcomingPage,
        DeadlineSummary,
        RuleStats,
        ReclaimedDay,
        ReclaimedSummary,
        Overview,
        ActivityItem,
        ItemExplanation,
        PreviewSample,
        RulePreview,
        Health,
        ServiceError,
        Acknowledgement,
        RequestEnvelope,
        ResponseEnvelope
    );
    for value in samples["requests"].as_array().unwrap() {
        let parsed: Request = serde_json::from_value(value.clone()).unwrap();
        assert_ne!(parsed, Request::Unknown);
        assert_eq!(serde_json::to_value(parsed).unwrap(), *value);
    }
    for value in samples["responses"].as_array().unwrap() {
        let parsed: Response = serde_json::from_value(value.clone()).unwrap();
        assert_ne!(parsed, Response::Unknown);
        assert_eq!(serde_json::to_value(parsed).unwrap(), *value);
    }
}
