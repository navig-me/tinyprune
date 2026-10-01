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

The Rules screen can add a user-selected managed root and an all-items rule that defaults to 30 days after modification in Preview; it can pause rules or resume them in Preview. Root bookmarks and policy updates are persisted transactionally. FSEvents indexing, resolving bookmarks in the agent, live match previews, and due-deadline scheduling are not active yet, so the editor does not claim to show live matches or perform automatic cleanup.


### Phase 1 — safe core before UI

- Implement domain models, validation, config codec/schema, duration/date parsing, glob behavior, rules/templates, and the resolver/explanation result.
- Build migrated SQLite storage, transactional audit log, xattr codec, identity resolver, and deterministic fake clock/filesystem abstractions for tests.
- Implement direct-user mutations: Keep, Inherit, explicit expiry, descendant protection, rule pause, root pause, global pause.
- Implement Trash preflight and executor against temporary test volumes/directories. Add durable tests for precedence, stale/replaced identity, parent protection, pause races, removed roots, and Trash failure.

**Exit proof:** a throwaway fixture tree proves kept descendants prevent parent trashing, preview creates no Trash move, and active eligibility moves only the validated candidate to Trash while producing an audit event.

### Phase 2 — event-driven index and agent

- Add streaming initial index/recovery, FSEvents watch management, event coalescing/reconciliation, project detection/activity, deadline invalidation, scheduler wake/sleep, mount lifecycle, and database maintenance.
- Bound every queue and batch. Instrument only local diagnostics needed to verify idle CPU, memory, database writes, backlog, and recovery—not user telemetry.
- Run a 100k-entry benchmark fixture and an idle soak scenario; define acceptance thresholds from the spec before optimising.

**Exit proof:** create/rename/modify events update only affected candidates; due candidates run one preflight; idle agent has no periodic full-tree traversal; crash/restart reconstructs operational state without violating Keep policies.

### Phase 3 — product surfaces

- Implement the three-step onboarding with templates and security-scoped folder chooser. Apply broad Developer Cleanup in Preview by default.
- Build the reference UI faithfully as a native macOS interpretation: warm stone canvas, plum primary, green success, amber caution; Newsreader display type, Manrope controls, JetBrains Mono paths; calm sidebar/navigation and inspector patterns.
- Implement Overview, natural-language Rules/editor with live impact preview, Upcoming grouping and Why inspector, Activity, Templates, Settings, menu bar, and notifications only for attention-required failures.
- Build Finder Sync menus for Keep, expiry presets, Inherit, folder lifetime/protection/rule creation, and Why. Each invokes the agent and handles unavailable-agent/access errors clearly.
- Build CLI commands in the specification, including schema-versioned JSON (`--json`) and config `validate`, `preview`, and `apply`; all mutations route through XPC.

**Exit proof:** manual smoke through onboarding → Preview rule → inspector explanation → Keep → active rule → Trash → Activity; Finder and CLI call the same agent and show the same resolved policy.

### Phase 4 — hardening, accessibility, and release readiness

- Add test fixtures for APFS identity changes, permissions revoked, unavailable volumes, xattr conflicts, large trees, glob boundaries, project activity noise, interrupted moves, agent restart, malformed configuration, and Finder/CLI unavailable-agent behavior.
- Test VoiceOver labels, keyboard paths, Dynamic Type/accessibility sizing where applicable, contrast, focus order, reduced motion, and localized date/duration/path rendering. Preserve exact paths in copyable mono text.
- Run real-device/manual verification for a signed app under standard user permissions, not Full Disk Access. Document limitations for external HFS+, cloud roots, and unavailable roots.
- Ship privacy policy, support/recovery documentation, open-source license decisions, release notes, and an incident/rollback runbook before public distribution.

## GitHub Actions and distribution

### Repository workflows

1. **`ci.yml`** — runs for pull requests and the protected default branch: validates `website/` and `docs/`, then, once the native project exists, runs dependency resolution, `swift test`, `xcodebuild test` for all test plans, configuration/schema validation, and a non-secret unsigned archive smoke build. Upload test results and coverage artifacts on failure. Cache only derived/dependency data keyed by lockfiles and Xcode version.
2. **`deploy-pages.yml`** — runs only from `main` (or a deliberate manual dispatch) and uses Cloudflare Pages Direct Upload to publish `website/` to the `tinyprune` Pages project (`tinyprune.com`) and `docs/` to `tinyprune-docs` (`docs.tinyprune.com`). Bind the job to a reviewer-protected `cloudflare-pages-production` GitHub Environment containing a least-privilege Pages API token and account ID.
3. **`release.yml`** — manually dispatchable dry run and protected `vX.Y.Z` tag release. It re-runs quality gates, verifies the tag equals the source version, archives universal app and CLI, signs with Developer ID, notarizes with `notarytool`, staples, validates Gatekeeper acceptance, packages DMG, generates checksums/SBOM/provenance, and publishes a GitHub Release only after those checks pass.
4. **`publish-update-feed.yml`** — called only by a successful release. Sign a Sparkle appcast using a separately protected EdDSA private key, publish the DMG-specific appcast and release notes to the website/update-feed repository or protected branch, then verify the public feed can be fetched and its enclosure checksum/signature matches the released DMG.
5. **`homebrew.yml`** — called only by a successful release and creates a signed commit/PR to the dedicated `tinyprune/homebrew-tap` cask repository. The cask pins the release URL and SHA-256, installs `TinyPrune.app`, and declares the bundled `tinyprune` binary. Verify installation and `tinyprune status --json` in a clean macOS CI job before auto-merging only after repository policy permits it.

`website/` and `docs/` are intentionally separate dependency-free static sites. Configure their Pages projects as Direct Upload projects; set custom domains in Cloudflare, never in source. See `.github/DEPLOYMENT.md` for the required project names, GitHub Environment, and secrets.

Use GitHub Environments (`release`, `cloudflare-pages-production`, `update-feed`, `homebrew`) with required reviewers and narrowly scoped secrets: App Store Connect API key or notarization API key, Developer ID certificate/profile in an encrypted ephemeral keychain, Sparkle EdDSA key, website publishing credential, and a fine-grained tap-repository token. Never expose signing material to pull requests or forked workflows.

### Update-channel policy

- **Direct DMG:** Sparkle 2, HTTPS appcast, EdDSA-signed feed/enclosures, code-signed and notarized app. Offer automatic checks and user-visible release notes; never auto-install while the app/agent is actively performing a Trash operation.
- **Homebrew:** publish through the cask only. Ship a Homebrew-specific build configuration with Sparkle automatic checks disabled, so `brew upgrade --cask tinyprune` is the sole updater. Keep app bundle version/build identical to the release tag and test this configuration separately.
- **Rollbacks:** retain prior notarized DMGs and feed entries. A rollback release increments the app version and points to a known-safe artifact; never mutate an already-published artifact or silently downgrade users.

## Decisions to make before implementation begins

1. Confirm macOS deployment floor after the FSEvents/Finder Sync/Sparkle compatibility spike; use Sonoma unless a supported customer base requires lower.
2. Create Apple Developer Program, Developer ID Application certificate, notarization API key, Sparkle EdDSA signing key, GitHub Environments, protected default branch, and the Homebrew tap repository before building distribution automation.
3. Confirm the public update-feed hosting location under `tinyprune.com`; it must serve immutable HTTPS DMGs and appcast XML with correct cache control.
4. Confirm whether the Finder interface ships as Finder Sync (recommended for v1) versus a Finder Quick Action. The spec’s contextual submenu maps naturally to Finder Sync, but entitlement/sandbox behavior needs an early real-device spike.

## First implementation ticket

Start Phase 0 with a minimal unsigned app + XPC agent + CLI health endpoint and a single `TinyPruneDomain` test target. In parallel inside that ticket, prototype: security-scoped bookmark persistence, FSEvents delivery for one chosen root, moving one temporary fixture to Trash, and Finder Sync menu availability. These spikes retire platform-risk before schema or UI work grows around assumptions.
