# tinyprune-cli (in development, unreleased)

IPC-only command-line client producing the `tinyprune` binary. TinyPrune remains publicly macOS-only; this internal Rust work is not a released Linux or Windows product. The client contains no rule evaluator, enumerator, store, or Trash executor. All operational mutations and decisions are agent RPCs. It never writes managed files or configuration files; export writes stdout, and import reads an explicitly supplied file or stdin.

## Connection

Run the Rust background agent (`tinyprune-agentd`, from `tinyprune-daemon`) before using this client. Endpoints use `tinyprune_ipc::default_endpoint()`: Linux `$XDG_DATA_HOME/tinyprune/agent.sock` or `$HOME/.local/share/tinyprune/agent.sock`, macOS `$HOME/Library/Application Support/TinyPrune/agent.sock`, Windows `\\.\pipe\tinyprune-agent-{current-user-SID}`. Selection precedence is `--socket <path>`, `TINYPRUNE_ENDPOINT`, `TINYPRUNE_SOCKET`, then the platform default. Unix transports authenticate the effective uid; Windows named pipes authenticate the current user SID. This is not the released macOS application's XPC protocol.

## Command reference

Every command accepts `--json`; omitting the command defaults to `status`. `--help`, `-h`, and `help` print usage. Unknown flags and extra/missing operands fail with exit 64 before connecting. `--` ends command option parsing, allowing a path beginning with `-`. Relative paths are made absolute lexically; the agent performs authoritative path, root, rule and safety validation.

| Command | Behavior |
| --- | --- |
| `status` | Agent protocol and service version |
| `rules` / `rules list` | Rules and global pause state |
| `rules add <rule.json\|->` | Save a complete IPC `Rule` JSON DTO; agent validates it |
| `rules edit <id> <rule.json\|->` | Save supplied rule fields using the specified id |
| `rules remove <id>` / `delete-rule <id>` | Remove rule |
| `rules activate <id>` | Load rule, save Active state with loaded policy revision |
| `rules preview <id>` | Read-only, nonpersisting Preview RPC; full sample explanations and truncation warning |
| `upcoming` | Read all cursor pages, showing every full explanation |
| `keep <path> [--descendants]` | Explicit Keep override |
| `unkeep <path>` / `inherit <path>` | Clear explicit override; return to inherited policy |
| `expire <path> <when>` | Active custom expiry override |
| `explain <path>` / `why <path>` | Complete decision and considered overrides |
| `pause [when]` / `resume` | Indefinite or timed global pause / resume |
| `activity` | Latest 50 audit events; decision events include full explanations |
| `roots` / `roots list` | Managed roots |
| `roots add <id> <path> [name]` | Ask agent to validate/add a managed root |
| `roots remove <id>` | Remove managed root |
| `config export` | Configuration text on stdout (JSON key `config` with `--json`) |
| `config import <file\|-> [--active]` / `config apply ...` | Send config text with current revision; agent parses and imports, Preview by default |
| `doctor` | Health, overview/index/root states, settings and full upcoming decisions |
| `rebuild-index` | Ask agent to rebuild index |

`-` reads rule/config input from stdin. A complete rule example is `Rule` in [`../../Fixtures/ipc/dtos.json`](../../Fixtures/ipc/dtos.json); its required fields are `id`, `name`, `scope`, `matcher`, `expiryBasis`, `lifetime` (seconds), `gracePeriod` (seconds or null), `action`, `state`, and `matchMode`. The agent, not this client, authorizes activation and forces broad rules to Preview.

Expiry values accept positive integers with `m`, `h`, `d`, or `w`, plus `tonight` (next 23:59 local time) and `tomorrow` (same local time next day). Day/week values preserve local calendar time across daylight-saving transitions. Timed pause additionally accepts `today` (next local midnight); pause `tomorrow` resumes at 08:00 the next day, matching the Swift CLI. Human dates use explicit Unix seconds rather than Swift's locale-dependent date formatting. Nonexistent local calendar instants fail rather than guessing.

The Swift CLI's local `config validate` and config diff/plan `config preview` have no Rust IPC operations and are intentionally rejected, not reimplemented using a second policy/config evaluator. Rust import is the agent's transaction, with no automatic conflict retry or transport retry. Rule save/import carry the loaded revision. A disconnected request may already have applied: inspect current state before retrying.

## Output and exits

JSON documents carry `schemaVersion: 1`; rules, upcoming, activity, explain, export and mutations preserve Swift's top-level shapes where the wire DTOs permit. Rust DTO field spellings/Unix dates follow the IPC README, not Swift Codable. Human output keeps Swift's status/empty-list/mutation wording where applicable and expands every decision into all explanation fields (including null context, full rule and identity). Preview counts explicitly warn when truncated.

Success is 0; usage 64; invalid data/request 65; agent unavailable, root unavailable or protocol mismatch 69; storage/unexpected reply 70; policy conflict, busy or interrupted request 75. JSON errors are stdout, human errors stderr. An unreachable agent preserves Swift's exact JSON `{ "schemaVersion": 1, "status": "unavailable" }` object (compact on the wire); human errors explain how to start the agent. Protocol mismatch errors tell users to update/restart. Errors after sending mark `mayHaveApplied: true`; mutations are never retried automatically. Exit 78 is reserved by Swift for config roots not already managed; Rust imports report the authoritative agent error instead.

## Dependencies and verification

`tinyprune-ipc` is the sole operational dependency. `serde`/`serde_json` encode CLI output and decode supplied wire rule DTOs; no policy parsing/evaluation is duplicated. `chrono` with only `clock`/`std` closes the standard library's missing cross-platform local calendar and daylight-saving arithmetic required for Swift-compatible tonight/tomorrow/day/week expiry and pause presets. Argument parsing uses only std.

From `rust/`:

```sh
cargo test --locked -p tinyprune-cli
cargo clippy --locked -p tinyprune-cli --all-targets -- -D warnings
cargo check --locked -p tinyprune-cli --target x86_64-unknown-linux-gnu --all-targets
cargo check --locked -p tinyprune-cli --target x86_64-pc-windows-msvc --all-targets
```

Tests use fake `AgentService` implementations behind actual loopback framing/handshakes and a real Unix socket, covering every command's human/JSON output, full explanation fields, revision forwarding, unavailable/mismatched agents, service exit codes, and stable human-output assertions. Native Windows/Linux runtime execution remains a separate acceptance requirement; cross-compilation does not establish it.
