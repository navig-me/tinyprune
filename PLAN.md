# TinyPrune implementation plan

## Product boundary

Deliver the deterministic, local-first macOS v1 in `spec.md`: lifecycle rules schedule candidates and only move verified eligible items to the macOS Trash. No permanent deletion, network dependency, account, content inspection, agentic features, or generic system-cleaner functionality.

**Release target:** macOS 14+ (Sonoma) on Apple Silicon and Intel, pending a first compatibility spike for the Finder Sync extension and chosen Sparkle release.

## Principles and non-negotiable invariants

1. The database schedules work; it never authorizes a Trash operation. Re-evaluate identity, permissions, current rule resolution, protection, pause state, deadline, and volume availability immediately before every move.
2. Work scales with filesystem events and due deadlines—not repeated scans of the managed tree. Initial index and recovery are bounded, streaming enumerations.
3. Explicit `Keep` always wins. A parent cannot be trashed if it contains a protected descendant; eligible children may still be evaluated individually.
4. Every candidate must explain its matched rule, expiry basis, resolved deadline, project root/activity when applicable, overrides, and how to stop it.
5. Normal file handling reads metadata only. All state stays on-device.
6. Broad/new rules begin in Preview; Preview executes matching, index updates, scheduling, and audit logging but never invokes Trash.

## Architecture decision

Create a native Swift Package workspace plus an Xcode application project. SwiftUI owns application screens; AppKit owns native macOS integration. Keep all policy and filesystem behavior outside views and extension targets.

```text
TinyPruneApp (SwiftUI/AppKit) ─┐
Finder Sync extension ─────────┼─ XPC ─► TinyPruneAgent
CLI executable ────────────────┘          ├─ FSEvents watcher
                                           ├─ incremental indexer
                                           ├─ rule/project/safety engines
                                           ├─ deadline scheduler
                                           ├─ Trash executor
                                           └─ SQLite store + xattrs
```

### Proposed targets and modules

| Target/module | Responsibility |
|---|---|
| `TinyPruneDomain` | `Sendable`, Codable rule/override/deadline/audit types; validation; deterministic precedence and explanation models. No filesystem or UI APIs. |
| `TinyPrunePersistence` | SQLite migrations, repositories, transactional writes, xattr codec, identity mapping, index recovery. Use a mature Swift SQLite wrapper only if it preserves prepared statements, migrations, and concurrency control. |
| `TinyPruneEngine` | Rule evaluator, glob matcher, project-root/activity resolver, initial streaming indexer, FSEvents reconciliation, deadline scheduler, safety preflight, Trash service. |
| `TinyPruneIPC` | Versioned XPC protocols and DTOs shared by app, agent, CLI, and Finder extension. All mutation APIs return durable audit/event IDs and explainable outcomes. |
| `TinyPruneAgent` | LaunchAgent/XPC service process; owns all mutable operational state and filesystem access. |
| `TinyPruneApp` | Onboarding, Overview, Rules/editor, Upcoming/inspector, Activity, Templates, Settings, menu bar. |
| `TinyPruneFinderExtension` | Finder Sync menus only; forwards selected URLs and commands to the agent. No cleanup engine in the extension. |
| `tinyprune` | ArgumentParser-based CLI client of XPC; human output plus stable JSON schema. |

Use Swift actors for store coordination and agent orchestration. Restrict filesystem handles/bookmarks to one access layer. Keep `NSFileCoordinator`/security-scoped access policy centralized so it can be tested and audited.

## Data and filesystem design

### Identity and permissions

- Managed roots are user-selected security-scoped bookmarks; persist the bookmark and refresh stale bookmarks through explicit user remediation.
- Record `(volume UUID, file resource identifier, path hint)` for managed roots, overrides, projects, and deadlines. Path is a lookup hint, never authorization identity.
- Resolve resource values without file-content reads. Do not follow symlinks by default; make any future traversal setting explicit and safety-reviewed.
- Reject `/`, system locations, `/Applications`, and equivalent dangerous roots. Require Preview and an explicit warning for overly broad home-directory scopes.
- Model disconnected removable volumes as dormant; subscribe to mount changes rather than polling. Mark cloud provider roots cautious until their placeholder semantics are explicitly supported.

### Persistence schema and migrations

Implement versioned migrations for `managed_roots`, `rules`, `rule_scopes`, `item_overrides`, `projects`, `deadlines`, `audit_events`, and `settings`. Include `deadlines(expires_at)` plus indexes for identity lookup, root/scope lookup, rule state, and audit chronology.

Store explicit item policies redundantly in a versioned, minimal `com.tinyprune.*` xattr payload and SQLite. Never write inherited policy xattrs. On index rebuild: load root/rule configuration, enumerate streaming batches, reconcile valid xattrs, and derive inherited schedules anew. Treat disagreement as an auditable reconciliation event, never a blind overwrite.

### Rule resolution and scheduling

1. Define the complete typed rule grammar: scope, depth, type, exact names/globs (regex gated as Advanced), expiry basis/duration/grace, folder action, state, and exclusions.
2. Implement a single resolver that returns either no action or a fully explained decision. Encode the specified precedence order and test every tie/override boundary.
3. Calculate deadlines after an initial/event-driven evaluation and persist them. A priority query wakes the agent for the next due deadline; rule/root/override events invalidate only affected scopes.
4. Detect project roots from the supplied marker set. Record meaningful project activity from FSEvents while ignoring the supplied generated/noisy patterns. Project activity must not rely on Git commands or source-code inspection.
5. At the due time, run safety preflight in one agent transaction: reload current state, re-resolve identity and rule, inspect protection ancestors/descendants, enforce pause/grace/availability, then move through macOS Trash APIs. Record every outcome.

## Delivery sequence

### Phase 0 — engineering foundation

- Create the Xcode project/workspace, Swift package modules, shared build settings, entitlements, signing configuration, app/agent/Finder extension/CLI targets, and local development scheme.
- Define bundle identifiers, app group/keychain access strategy only where required, SQLite location, security-scoped bookmark policy, minimum macOS version, and no-network privacy posture.
- Add formatting/linting only if pinned and deterministic; use `swift test`, `xcodebuild test`, and a reusable simulator-free macOS test command as the initial quality gate.
- Write ADRs for: XPC boundary, identity model, policy precedence, safety preflight, SQLite/xattr reconciliation, and update-channel separation.

**Exit proof:** all targets compile, app launches, the agent accepts a versioned XPC health request, and CLI receives that response.

#### Local packaged-app loop

On macOS, run `swift Scripts/package-app.swift` to build and ad-hoc sign the development `.app` bundle at `.build/package/TinyPrune.app`. Open it with `open .build/package/TinyPrune.app`; the app offers to register the embedded LaunchAgent through `SMAppService` and opens Login Items for approval when needed. Then use `swift run tinyprune status`, `rules`, or `upcoming` from the repository. The package is for local development only: Developer ID signing, notarization, and release packaging remain separate release steps.

The Rules screen adds user-selected managed roots and Preview rules; bookmarks and policy updates persist transactionally. The agent registers FSEvents before bounded initial indexing, persists identity-based deadlines and observed activity, and wakes the due scheduler. The editor offers an explicit bounded read-only impact preview rather than automatically scanning while the user types; see Phase 3 and ADR 0003.


### Phase 1 — safe core before UI

- Implement domain models, validation, config codec/schema, duration/date parsing, glob behavior, rules/templates, and the resolver/explanation result.
- Build migrated SQLite storage, transactional audit log, xattr codec, identity resolver, and deterministic fake clock/filesystem abstractions for tests.
- Implement direct-user mutations: Keep, Inherit, explicit expiry, descendant protection, rule pause, root pause, global pause.
- Implement Trash preflight and executor against temporary test volumes/directories. Add durable tests for precedence, stale/replaced identity, parent protection, pause races, removed roots, and Trash failure.

**Exit proof:** a throwaway fixture tree proves kept descendants prevent parent trashing, preview creates no Trash move, and active eligibility moves only the validated candidate to Trash while producing an audit event.

### Phase 2 — event-driven index and agent

- Add streaming initial index/recovery, FSEvents watch management, event coalescing/reconciliation, project detection/activity, deadline invalidation, scheduler wake/sleep, mount lifecycle, and database maintenance.
- Bound every queue and batch. Instrument only local diagnostics needed to verify idle CPU, memory, database writes, backlog, and recovery—not user telemetry.
- Acceptance thresholds on the macOS 15 benchmark runner: `swift test -c release -Xswiftc -enable-testing --filter PhaseTwoBenchmarkTests` (Swift Testing; on a CommandLineTools-only Mac add the framework flags in AGENTS.md) indexes 100,000 files within 5 minutes with peak RSS at or below 512 MiB; its 60-second idle soak uses at most 0.5 CPU-seconds and triggers no full-tree scan; each root event buffer remains at most 512 batches and persistence batches at most 256 rows. Observed locally (release): 48.5 s scan, 56 MiB peak RSS, 0.0013 idle CPU-s, persistence batches 256.
- Exit fixtures must cover create, rename, modify, event-overflow recovery, crash/restart, one final preflight for each due candidate, and Keep preservation. Report scan duration, peak RSS, CPU time, queue/batch high-water marks, and recovery count as local diagnostics only.

**Exit proof:** create/rename/modify events update only affected candidates; due candidates run one preflight; idle agent has no periodic full-tree traversal; crash/restart reconstructs operational state without violating Keep policies.

### Phase 3 — product surfaces

- Implement the three-step onboarding with templates and security-scoped folder chooser. Apply broad Developer Cleanup in Preview by default.
- Build the reference UI faithfully as a native macOS interpretation: warm stone canvas, plum primary, green success, amber caution; Newsreader display type, Manrope controls, JetBrains Mono paths; calm sidebar/navigation and inspector patterns.
- Implement Overview, natural-language Rules/editor with live impact preview, Upcoming grouping and Why inspector, Activity, Templates, Settings, menu bar, and notifications only for attention-required failures.
- Build Finder Sync menus for Keep, expiry presets, Inherit, folder lifetime/protection/rule creation, and Why. Each invokes the agent and handles unavailable-agent/access errors clearly.
- Build CLI commands in the specification, including schema-versioned JSON (`--json`) and config `validate`, `preview`, and `apply`; all mutations route through XPC.

**Exit proof:** manual smoke through onboarding → Preview rule → inspector explanation → Keep → active rule → Trash → Activity; Finder and CLI call the same agent and show the same resolved policy.

#### Phase 3 implementation notes

- **Agent contract.** `TinyPruneIPC` adds `loadActivity`, `explainItem`, `setItemOverride`, `clearItemOverride`, `setGlobalPause`, `deleteRule`, and `rebuildIndex`. Every mutation writes its audit event in the same SQLite transaction (`ruleCreated/Edited/Paused/Deleted`, `itemProtected/Unprotected`, `expiryChanged`, `globalPauseChanged`). Item overrides are accepted only for paths inside an available managed root and are identity-bound.
- **Impact preview is an explicit dry run.** Saving as Preview indexes a rule and counts come from the persisted deadline index. The editor's "Preview matches" button additionally runs a user-initiated, bounded, read-only dry run (`previewRule`, ADR 0003) that never writes or trashes. Permission/traversal errors fail with a readable path and remediation instead of reporting an exact zero-match result; restoring access permits a complete preview.
- **Templates** (`RuleTemplate`) produce ordinary `LifetimeRule`s. Developer templates and very broad folders (home, `/Users`, `/Volumes`) are forced into Preview.
- **Finder.** `TinyPruneFinderExtension` is a sandboxed thin XPC client (mach-lookup exception for the agent only, see `Resources/Entitlements`). Set Folder Lifetime, Create Rule, and Custom… hand off one selected item through `tinyprune://folder|rule|expire?path=`; multi-selection disables these single-editor handoffs. Menu actions use the selection captured when the menu opened. Managed-root notifications refresh the monitored folders. Earlier sandboxed XPC harness verification passed; actual Finder clicks remain unverified. The current account has no registered extension and lacks Accessibility automation permission.
- **CLI.** Every `--json` document carries `schemaVersion: 1`. `config validate|preview|apply|export` reads a restricted YAML subset (`ConfigDocument`); `apply` only works inside folders already managed in the app because only the app creates security-scoped bookmarks.
- **Signing identity.** Security-scoped bookmarks created by the app only resolve in the agent when both share a signing identifier. `Scripts/package-app.swift` signs app, agent, and CLI with `com.navig-me.tinyprune` and the appex with its own id and entitlements; `Scripts/verify-signing.sh` enforces this (ADR 0004). Ad-hoc universal direct and Homebrew bundles pass the verifier, including embedded Sparkle helpers. Developer ID signing, notarization, and a genuine signed update remain unverified without Apple credentials.
- **Timed pause and settings** are enforced by the agent: pause-until lapses from a clock, default grace, hidden-file protection, and activity retention apply to every client.

### Phase 4 — hardening, accessibility, and release readiness

- Add test fixtures for APFS identity changes, permissions revoked, unavailable volumes, xattr conflicts, large trees, glob boundaries, project activity noise, interrupted moves, agent restart, malformed configuration, and Finder/CLI unavailable-agent behavior.
- Test VoiceOver labels, keyboard paths, Dynamic Type/accessibility sizing where applicable, contrast, focus order, reduced motion, and localized date/duration/path rendering. Preserve exact paths in copyable mono text.
- Run real-device/manual verification for a signed app under standard user permissions, not Full Disk Access. Document limitations for external HFS+, cloud roots, and unavailable roots.
- Ship privacy policy, support/recovery documentation, open-source license decisions, release notes, and an incident/rollback runbook before public distribution.

#### Current acceptance evidence and remaining gates

- The prescribed CommandLineTools Swift Testing command in the contributor guide passed **75 tests in 14 suites**. Its 100,000-file benchmark observed a 38.8 s scan, 68,083,712-byte peak RSS, 256-row persistence batches, zero idle full-tree scans and 0.000951 idle CPU-seconds over 60 seconds.
- `TinyPruneDomainCheck` and `TinyPruneEngineCheck` passed actual fixture scenarios for events, restart, project activity, overrides, Preview, scheduling, real Trash and protected descendants.
- `TinyPruneUISnapshots` renders native views using a real in-process agent and disposable filesystem tree. The final quick run passed **57 assertions** and wrote 49 PNGs, including actual Preview → Keep → active Trash → Activity → restart and keyboard-triggered permission failure/recovery. The full render run also exercised 1×/2× and accessibility-size environments; dark/high-contrast native appearances and long paths were inspected.
- Offscreen rendering is **not** real VoiceOver acceptance: SwiftUI's assistive node tree is unavailable to that harness, and native sidebar snapshotting is incomplete. Actual reading/focus order, full keyboard navigation, system text scaling and reduced-motion settings still require a disposable interactive GUI account. No TCC settings were changed.
- Sparkle 2.9 integration, update/Trash exclusion, persisted pending markers, resume/recovery, deadline retention and event-driven resumption are implemented (ADR 0006). Signed feed/note tooling accepted original ephemeral fixtures and rejected altered bytes; genuine signed older/newer app installation remains a separate release gate.
- A plain disposable DMG reproduces this host's `diskutil eject` stall outside TinyPrune/Homebrew. No cask workaround was added. CI run 37184566181 passed on fresh `macos-15` arm64 and `macos-15-intel` runners: 75 tests, engine fixtures, UI smoke (56 assertions), both packaging channels and a real unattended cask install with no eject stall. GitHub runner accounts are administrators, so this does not prove standard-user operation, background-item approval or Gatekeeper acceptance.


## GitHub Actions and distribution

### Repository workflows

1. **`ci.yml`** — validates both static sites and runs native acceptance on fresh `macos-15` arm64 and `macos-15-intel` runners: Swift Testing (including the 100k benchmark), real engine fixtures, native view/lifecycle smoke, direct/Homebrew packaging and a real unattended local-tap cask install with the shared release renderer. It uploads logs and native PNGs. The cask smoke is restricted to disposable GitHub-hosted runners, never registers an agent and does not zap user configuration; it does not prove interactive Finder/background-item approval or signed Gatekeeper acceptance.
2. **`deploy-pages.yml`** — runs only from `main` (or a deliberate manual dispatch) and uses Cloudflare Pages Direct Upload to publish `website/` to the `tinyprune` Pages project (`tinyprune.com`) and `docs/` to `tinyprune-docs` (`docs.tinyprune.com`). Bind the job to a reviewer-protected `cloudflare-pages-production` GitHub Environment containing a least-privilege Pages API token and account ID.
3. **`release.yml`** — manually dispatchable dry run and protected `vX.Y.Z` tag release. It re-runs quality gates, verifies the tag equals the source version, archives the universal app and CLI, packages a DMG, and generates checksums. With all six Apple secrets it signs with Developer ID, notarizes with `notarytool`, staples, and validates Gatekeeper acceptance. With none, it publishes an ad-hoc signed, clearly labeled **pre-release** (ADR 0005); partial credentials or a mode mismatch fail the run with no fallback. Two DMGs are built: direct and Homebrew (the Homebrew build disables Sparkle automatic checks). SBOM/provenance are not produced yet.
4. **`publish-update-feed.yml`** — called only by a successful signed-or-stable release, never for unsigned previews. Signs the final Sparkle 2.9 appcast, immutable direct DMG and release-note bytes with a separately protected EdDSA key; verifies the DMG against the public key embedded in the released app; opens a reviewed PR; and verifies public bytes after Pages deploy through manual `verify_public`. Missing private keys skip publication. The app now links Sparkle, but actual checks are enabled only for Developer ID direct builds with the matching public key.
5. **`homebrew.yml`** — called by a release and opens a PR to the dedicated `tinyprune/homebrew-tap` cask repository using a protected, narrowly scoped token. The cask pins the release URL and SHA-256, installs `TinyPrune.app`, and declares the bundled `tinyprune` binary. A clean macOS job installs from the PR branch and runs `tinyprune status --json`. It skips cleanly when the token is absent.

`website/` and `docs/` are intentionally separate dependency-free static sites. Configure their Pages projects as Direct Upload projects; set custom domains in Cloudflare, never in source. See `.github/DEPLOYMENT.md` for the required project names, GitHub Environment, and secrets.

Use GitHub Environments (`release`, `cloudflare-pages-production`, `update-feed`, `homebrew`) with required reviewers and narrowly scoped secrets: App Store Connect API key or notarization API key, Developer ID certificate/profile in an encrypted ephemeral keychain, Sparkle EdDSA key, website publishing credential, and a fine-grained tap-repository token. Never expose signing material to pull requests or forked workflows.

### Update-channel policy

- **Direct DMG:** pinned Sparkle 2.9, HTTPS appcast, EdDSA-signed feed/notes/enclosures, code-signed and notarized app. Offer automatic checks and user-visible release notes, but no automatic installation. The updater obtains an exclusive cross-process gate before a downloadable update; every Trash execution holds a shared permit through preflight, move and audit. Pending updates inhibit cleanup across process exit; successful signed target recovery reconciles an already-enabled bundled agent before resuming. Due deadlines are retained while blocked and a filesystem event wakes the scheduler when the marker clears.
- **Homebrew:** publish through the cask only. Ship a Homebrew-specific build configuration with Sparkle automatic checks disabled, so `brew upgrade --cask tinyprune` is the sole updater. Keep app bundle version/build identical to the release tag and test this configuration separately.
- **Rollbacks:** retain prior notarized DMGs and feed entries. A rollback release increments the app version and points to a known-safe artifact; never mutate an already-published artifact or silently downgrade users.

## Decisions to make before implementation begins

1. Confirm macOS deployment floor after the FSEvents/Finder Sync/Sparkle compatibility spike; use Sonoma unless a supported customer base requires lower.
2. Create Apple Developer Program, Developer ID Application certificate, notarization API key, Sparkle EdDSA signing key, GitHub Environments, protected default branch, and the Homebrew tap repository before building distribution automation.
3. Confirm the public update-feed hosting location under `tinyprune.com`; it must serve immutable HTTPS DMGs and appcast XML with correct cache control.
4. Confirm whether the Finder interface ships as Finder Sync (recommended for v1) versus a Finder Quick Action. The spec’s contextual submenu maps naturally to Finder Sync, but entitlement/sandbox behavior needs an early real-device spike.

## First implementation ticket

Start Phase 0 with a minimal unsigned app + XPC agent + CLI health endpoint and a single `TinyPruneDomain` test target. In parallel inside that ticket, prototype: security-scoped bookmark persistence, FSEvents delivery for one chosen root, moving one temporary fixture to Trash, and Finder Sync menu availability. These spikes retire platform-risk before schema or UI work grows around assumptions.
