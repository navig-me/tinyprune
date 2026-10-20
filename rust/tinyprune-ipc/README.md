# tinyprune-ipc (in development)

Unreleased, blocking local client/agent protocol. TinyPrune remains a macOS-only product; this crate does not establish or release Linux or Windows support. It does not host a daemon, implement policy/storage operations, or replace the macOS XPC product.

## Integration

Implement `AgentService::handle(Request) -> Response`, create `Server::new(Arc<dyn AgentService>, ServerOptions)`, then repeatedly accept connections from `unix::Listener` or `windows::Listener` and pass each to `Server::dispatch`. Dispatch returns a join handle; the embedding process owns listener cancellation, worker joining, and error reporting. Connections beyond `max_connections` are immediately dropped with `WouldBlock`, not queued in worker threads. The kernel has its own listen backlog. A worker handles multiple sequential requests per connection. Service implementations must synchronize their own mutable state, validate all DTO input (including unknown policy enums), preserve revision checks, and commit audits atomically with mutations. `Acknowledgement` includes durable audit IDs and the resulting revision. No transport request authorizes Trash; the agent must use the core preflight coordinator.

Clients call `Client::connect(stream, VersionRange, max_frame)` and then blocking `request`. `loopback::pair()` provides a bounded in-memory byte stream using the same framing, handshake, and dispatch as OS transports. Transport failure after sending a mutation means the outcome may be unknown; the client never automatically retries.

`default_endpoint() -> io::Result<PathBuf>` is shared by daemon, CLI and UI. It honors `TINYPRUNE_ENDPOINT`, then `TINYPRUNE_SOCKET`, rejecting empty overrides. Defaults: Linux `$XDG_DATA_HOME/tinyprune/agent.sock` (or `~/.local/share/tinyprune/agent.sock`); macOS `~/Library/Application Support/TinyPrune/agent.sock`; Windows `\\.\pipe\tinyprune-agent-{current-user-SID}`. The Windows SID suffix prevents different users competing for a global pipe name. The helper computes a path only; embedding code must create missing state-directory ancestors before binding. Unix socket path-length limits still apply; use an override for a long home path.

Both listener types expose `set_nonblocking(bool)` for daemon accept/tick loops; Unix takes `&self`, Windows `&mut self`. An empty nonblocking accept returns `WouldBlock`, while accepted worker streams remain blocking. Windows uses `PIPE_NOWAIT` only on the pending listening instance, not on connected request streams.

Every frame is a four-byte unsigned big-endian payload length followed by UTF-8 JSON. Zero-length and oversized frames fail before payload allocation. Encoding is also capped before any frame bytes are emitted. Default maximum: 1 MiB, configurable independently at each endpoint. The first frame must be `Handshake` with explicit `protocol_version` equal to the client's advertised maximum and a valid inclusive min/max range. The server selects the highest shared version or replies with `protocol_version: null` and closes. Request/response envelopes must use the selected version. This Rust wire protocol starts at **1**, independent of Swift XPC's current **3**.

All DTO structs ignore unknown fields. String enums decode unrecognized values as `Unknown`. RPC and override discriminants also accept unknown variants with arbitrary payloads; unknown requests are rejected without calling the service. Known operations with malformed arguments are errors, not silently downgraded to unknown. Unknown policy values must never be mapped to an active or permissive policy by an embedding service. This is additive-field evolution, not a promise that missing required fields can be invented.

`Explanation` contains item identity, scheduled/eligible time, full matched rule, expiry basis/date, project identity/activity, override, suppression reason, disposition and global pause. Inapplicable context is explicitly null. Upcoming items, explicit explanations and preview samples always carry it; activity events representing decisions must populate their explanation, while non-decision mutation events may use null. Preview is only an RPC contract: the service must use a non-mutating metadata-only preview implementation and never a Trash executor.

Operations cover Swift's health, policy/overview, filtered/cursor upcoming pages, activity, explanations, policy replacement, rule save/delete/preview/cancel, batched and individual overrides, pause/until, settings, metadata size, roots, and index rebuild. Rust additionally exposes root add/remove and config import/export; Swift CLI currently performs config parsing/rendering locally around policy RPCs. Config import carries a revision and an explicit activation choice; the implementation must retain the core config validation and Preview defaults.

## Update interlock operations

`QuiesceForUpdate { token, target, leaseSeconds }`, `ReleaseUpdateQuiesce { token }` and `LoadUpdateStatus` return `UpdateStatus { phase: idle|draining|quiesced, target, trashInFlight, leaseRemainingSeconds }` (ADR 0012). They are answered without the engine lock. Quiescing blocks new Trash at once, never cancels one in flight (`draining`), refuses a second holder with `Busy`, and expires by itself; only the token holder can release. An unknown phase is never treated as quiesced. These operations are the whole update surface of the agent: checking, downloading and installing run in the CLI (`tinyprune-update`), because the agent has no network access.

## Swift field-name relationship

The DTO inventory follows `Sources/TinyPruneIPC/AgentHealth.swift` and the CLI's `Sources/tinyprune/main.swift`, but this is **not** an XPC-compatible JSON encoding. Struct field names use camelCase matching Swift concepts, except acronym suffixes use serde spelling (`ruleId`, `rootId`, `auditEventIds`, versus Swift `ruleID`/`rootID`). Handshake fields deliberately use `protocol_version`; ordinary request envelopes use `protocolVersion`. RPC enums use explicit `operation`/`arguments` or `type`/`data` discriminants instead of Swift synthesized associated-value enum encoding. Overrides use `type`. Rust wire dates are finite Unix seconds (Swift's default Codable dates use the Foundation reference epoch); durations are seconds rather than a Swift duration wrapper. Resource identifiers are base64 strings; identity volume identifiers are strings. Roots never carry security-scoped bookmarks; granting native access is a separate embedding responsibility. Full explanation DTOs unify Swift's several resolution shapes and add project context to every applicable decision. No Swift parity enforcement is claimed.

`../../Fixtures/ipc/dtos.json` contains golden samples for every DTO and every request/response variant. Rust tests decode and re-encode all samples exactly. These are wire-schema samples, not replacements for the shared Swift-reference behavior fixtures.

## Local security and lifecycle limits

Unix endpoints require a non-symlink directory owned by the effective uid with mode 0700 (created if absent); the socket is mode 0600. Existing endpoints are never removed on bind. Accepted and client connections verify the peer effective uid using Linux `SO_PEERCRED` or macOS/BSD `getpeereid`. Dropping the listener removes only the socket inode it created, not its parent directory. Unix connections have 30-second read/write timeouts. Use an injectable path in a trusted parent directory; ancestors must not be writable by another user. Same-user processes are trusted, as in the Windows DACL model.

Windows endpoints must use a local `\\.\pipe\name`. The first instance reserves the name with `FILE_FLAG_FIRST_PIPE_INSTANCE`; every instance uses a protected DACL granting access only to the current process token's user SID. Remote pipe clients are rejected. Both endpoints verify the peer process token's user SID. Pipe handles and security allocations are RAII-owned. Windows I/O is synchronous and has no request deadline: a stalled same-user client can occupy one bounded worker until disconnected/process shutdown; named-pipe client connect reports busy rather than polling. Windows named pipes have been cross-target checked and linted, **not executed here**. Native Windows authentication, lifecycle and I/O acceptance remain required before any release.

Dependencies address concrete gaps: `serde`/`serde_json` implement the evolution-safe JSON wire contract; `libc` supplies Unix peer credential checks absent from std; the existing locked `windows` 0.62 bindings supply named pipes, process-token identity and explicit security descriptors absent from std. No async runtime is required. Resolved dependencies are pinned in the workspace Cargo.lock.

## Verification

From `rust/`:

```sh
cargo test --locked -p tinyprune-ipc
cargo clippy --locked -p tinyprune-ipc --all-targets -- -D warnings
cargo check --locked -p tinyprune-ipc --target x86_64-unknown-linux-gnu --all-targets
cargo check --locked -p tinyprune-ipc --target x86_64-pc-windows-msvc --all-targets
cargo clippy --locked -p tinyprune-ipc --target x86_64-pc-windows-msvc --all-targets -- -D warnings
```

Tests use no sleeps. The Unix test performs real socket requests and verifies 0700/0600 permissions; the mismatched-uid test supplies an expected uid different from the actual kernel-reported peer uid, exercising rejection without requiring privileged uid changes. It does not claim execution under another real user. Linux is cross-checked only here; the socket run is on macOS.
