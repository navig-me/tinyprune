//! Wire shape of the Trash/update interlock operations (ADR 0012).
use tinyprune_ipc::*;

#[test]
fn interlock_requests_and_status_roundtrip_with_stable_names() {
    let quiesce = Request::QuiesceForUpdate {
        token: "t0".into(),
        target: "0.2.0".into(),
        lease_seconds: 120,
    };
    let json = serde_json::to_value(&quiesce).unwrap();
    assert_eq!(
        json,
        serde_json::json!({"operation":"quiesceForUpdate","arguments":{"token":"t0","target":"0.2.0","leaseSeconds":120}})
    );
    assert_eq!(serde_json::from_value::<Request>(json).unwrap(), quiesce);
    for request in [
        Request::ReleaseUpdateQuiesce { token: "t0".into() },
        Request::LoadUpdateStatus,
    ] {
        let parsed: Request =
            serde_json::from_value(serde_json::to_value(&request).unwrap()).unwrap();
        assert_eq!(parsed, request);
        assert_ne!(parsed, Request::Unknown);
    }
    let status = Response::UpdateStatus(UpdateStatus {
        phase: UpdatePhase::Draining,
        target: Some("0.2.0".into()),
        trash_in_flight: 1,
        lease_remaining_seconds: Some(59.5),
    });
    let json = serde_json::to_value(&status).unwrap();
    assert_eq!(json["type"], "updateStatus");
    assert_eq!(json["data"]["phase"], "draining");
    assert_eq!(serde_json::from_value::<Response>(json).unwrap(), status);
}

#[test]
fn a_future_phase_is_never_mistaken_for_quiesced() {
    let parsed: UpdatePhase = serde_json::from_str("\"futurePhase\"").unwrap();
    assert_eq!(parsed, UpdatePhase::Unknown);
    assert_ne!(parsed, UpdatePhase::Quiesced);
}
