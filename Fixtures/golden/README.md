# Golden behavior fixtures

Language-neutral contract for TinyPrune's pure decision logic (`TinyPruneDomain`). The Swift implementation is the reference; any other implementation (see ADR 0010) must produce identical `expected` output for every `input`.

Swift verifies them in `Tests/TinyPruneGoldenTests/GoldenFixtureTests.swift`; Rust uses `rust/tinyprune-core/tests/golden.rs`.

```sh
# verify (part of the normal test run)
swift test --filter GoldenFixtureTests
# after an INTENTIONAL behavior change: rewrite `expected`, then review the git diff
TINYPRUNE_UPDATE_GOLDEN=1 swift test --filter GoldenFixtureTests
```

Edit `input` by hand; never hand-edit `expected`. Case names are unique per file. Optional `note` explains why a case exists.

## Format

One JSON object per line: `{"name", "note"?, "op", "input", "expected"}`. Canonical comparison: object keys unordered, numbers compared numerically.

Construction failures yield `{"error": "<RuleValidationError case>"}`: `invalidDuration`, `invalidScope`, `emptyMatcherPattern`, `emptyRuleName`. A case may not trigger two errors at once (which fires first is not part of the contract).

Times are Unix epoch seconds (numbers). UUIDs are upper-case canonical strings; ordering of ids is plain string comparison of the upper-case form.

## Input objects (defaults in parentheses)

- **identity** `{path, volume ("00000000-0000-0000-0000-00000000AAAA"), resource (hex, "01"), created?, generation?, persistent (true)}`
- **candidate** is an identity plus `{name (last path component), kind ("directory"), timestamps {created, modified, firstObserved, observedActivity, accessed, projectActivity, explicitDate}}`
- **scope** `{path, recursive (true)}`
- **matcher** `{kind ("fileOrDirectory"), names [], globs []}`
- **rule** `{id, name ("Rule"), scope, matcher ({}), basis ("modified"), lifetime (86400), grace?, action ("trashItem"), state ("active"), mode ("scoped")}`
- **override** `{id, identity?, path, policy {type: inherit|keep|customExpiry, protectDescendants (false), expiresAt, state ("active")}}`
- **settings** `{defaultGraceSeconds (0), protectHiddenFiles (false)}`

## Operations

| op | input | expected |
|---|---|---|
| `glob` | `pattern, relativePath, name?` | `{matches}` item-level matching (slashless pattern tests the name) |
| `path.normalize` | `path` | `{path}` |
| `scope.relative` | `scope, path` | `{relative: string or null}` |
| `matcher.match` | `matcher, relativePath, name?, kind ("file")` | `{matches, specificity: 0/1/2 or null}` |
| `rule.validate` | `rule` | `{valid: true}` |
| `identity.equals` | `a, b` | `{equal}` |
| `evaluate` | `rule, candidate, settings?` | scheduled or suppressed (below) |
| `resolve` | `candidate, rules, overrides?, globallyPaused?, settings?` | resolution (below) |
| `keep.covers` | `path, identity?, override, keptItemCurrentPath?` | `{covers}` |
| `keep.protectsDescendant` | `ancestor, childPath, childIdentity?, override, keptItemCurrentPath?` | `{protects}` |
| `config.parse` | `text, home` | document `{version, roots[{path,line}], rules[{name,kind,names,globs,basis,afterSeconds,graceSeconds?,line}], exceptions[{path,protectDescendants,line}], ruleIds[{root,rule,id}]}` or `{configError: {line: n or null, message}}`. Messages are user-facing and part of the contract. |
| `config.render` | `roots[paths], rules[], overrides[]` | `{text}` |
| `trash.execute` | scenario (below) | outcome, `calls`, `audit` |
| `template.rules` | `template, path, state ("active"), temporaryLifetime (259200)` | `{title, summary, suggestedFolder, isBroad, rules[]}`; generated random rule IDs omitted |
| `broadness` | either `path, resolvedPath?` or `rule` | `{isVeryBroad}` or `{isVeryBroad,isBroad}` |
| `root.validate` | `path, name ("Root"), bookmarkBytes (1), resolvedPath?` | `{valid,path,isVeryBroad}` or `{error: emptyName\|invalidPath\|dangerousPath\|emptyBookmark}` |
| `config.plan` | `text, home ("/Users/fixture"), currentRules [], previousText?, previousState ("preview"), managedRoots [], overrides [], activate (false)` | full deterministic plan: `roots, unmanagedRoots, added, changed[{before,after,fields}], removed, unchanged, merged, exceptions[{path,protectDescendants,isNew}], hasRuleChanges, isApplicable, addsPreviewRules, newExceptions[paths], summaryLines` |
| `schedule.scan` | scripted metadata scenario (below) | per-step item resolutions/protected-descendant flags and durable observations |

Results: `{result: "scheduled", ruleId, ruleName, basis, basisDate, eligibleAt, scheduledAt, disposition}`, `{result: "customExpiry", overrideId, expiresAt, disposition}`, `{result: "protected", overrideId, protectedPath, protectsDescendants}`, `{result: "suppressed", reason}`, `{result: "noRule"}`, `{result: "ambiguousRules" | "ambiguousOverrides", ids: [...]}`.

## Behaviors a port must not "fix"

These are deliberate or at least pinned, and several are traps for a non-Swift implementation:

- Exact-name matching, scope/prefix matching, Keep path comparison, and de-duplication/sorting of config names use Swift `String` semantics: canonical equivalence (NFC and NFD spellings are equal) and, for sorting, NFC scalar order rather than UTF-8 byte order. Glob matching is the opposite: a regex over raw Unicode scalars with no normalization, where `?` matches one scalar. A port needs both behaviors.
- Keep-override tie-breaking compares path length in grapheme clusters (Swift `String.count`), not bytes or scalars.
- Matching paths are normalized lexically (`.`/`..`/duplicate and trailing slashes), without case folding. Broadness and managed-root safety additionally compare lowercased lexical and canonical paths.
- A Keep override matches by identity OR by path, so a replaced item at a kept path stays protected. A custom-expiry override with an identity applies by identity only.
- Identity equality ignores `pathHint` and `isPersistent`; `created`/`generation` only count when both sides carry them.

## `trash.execute` scenarios

Drive the real `TrashCoordinator` against scripted collaborators. Input: `now`, `request {identity, source {rule: id} | {customOverride: id}, scheduledAt}`, either `snapshot` or an ordered `snapshots` list (the coordinator reads policy twice; the last entry repeats; `{error: true}` makes a read fail), each snapshot `{rules, overrides, roots[{path}], globallyPaused, settings}`. `filesystem`: `candidate` (or an ordered `candidates` list for successive inspections; `null` = missing), `symlinkAncestor`, `symlinkError`, `inspectError`, `walk` (`none|protected|indeterminate|error`, or an ordered list), `trashError` (message). Also `hydrated` (candidate returned by activity hydration), `auditFailsOn` (audit kinds whose write fails), `updatePending`, `measure {bytes, items, truncated}`, `walkLimits {maxEntries, maxSeconds}`.

Expected: `outcome` (`previewed|notDue|skipped|deferred|movedToTrash` with `deadline`/`reason`/`originalPath`+`trashedPath`) or `error` (`policyReadFailed|filesystemReadFailed|auditWriteFailed|filesystemOperationFailed|movedButAuditFailed|updateInstallationPending`; error text is not part of the contract), plus `audit` (ordered events: `kind`, `at`, `ruleId?`, `detail?`, `bytes?`, `itemCount?`) and `calls` (the exact order of filesystem operations). The order is the safety contract: policy re-read, identity re-verified, descendant walk, and a trash attempt audited before the move. Never move without it.

## Domain coverage and filesystem boundary

The four additional files cover templates (37 cases), broadness (63), roots (42), and config plans (37): 179 new cases, 513 total. Template results include editable rule content, top-level versus recursive scope, Preview coercion, paused state, custom temporary lifetime boundaries, and construction failures. Config plans pin state preservation/activation, ordered field diffs, removal only of config-owned rules under listed roots, unmanaged-root blocking, merged ordering, exception planning, and human-readable summaries.

`config.plan.previousText` builds existing config rules from a second valid document; these follow `currentRules` in input order. All serialized rules use the ordinary rule shape, with explicit defaults, sorted matcher sets, and `grace: null` when absent. Template rule IDs and exception IDs are random in Swift, so they are deliberately excluded.

Broadness/root fixtures use nonexistent fixture-safe paths. **`/Dev` is dangerous**: the denylist is case-insensitive and therefore treats it as `/dev`; use `/Develop` instead. Denylist checks use component boundaries, not arbitrary string prefixes. A path ending in `/Library` is forbidden, but a user Library cache subfolder is not automatically forbidden.

`resolvedPath` is an injected, already-normalized canonical resolver result, including any nonexistent tail. Swift checks both spellings through the reference public APIs; Rust injects the same result through `PathResolver`. This pins the pure classification decision for symlink aliases without creating host-specific symlinks. Actual `realpath` traversal, deepest-existing-ancestor discovery, and host home-directory discovery are filesystem-dependent and **not covered** by these portable fixtures. Do not use real aliases such as `/tmp` or `/private/var/tmp` as portable validation inputs: Foundation can standardize existing system aliases differently. Rule-form broadness fixtures omit resolution and host-specific homes. Rust adapters must supply canonical paths and home directories; an identity resolver is only the fixture default.

## `schedule.scan` scenarios

`schedule.jsonl` adds 64 deterministic indexing scenarios. Input: `root` (`"/Develop"`), `rules`, optional `overrides`/`settings`/`observations`, and either one `{now, tree, events?, removed?}` step or ordered `steps`. Each tree entry uses the ordinary candidate schema; include project parent directories and markers explicitly. Every entry must carry a distinct stable resource identifier unless it represents the same identity across steps. Prior observations use identity fields plus required `first`/`last` epoch seconds.

Each step supplies a complete metadata snapshot of the root, optional `restart: true`, ordered activity `events[{path, at}]`, and `removed[paths]`. Events carry the activity time (historical replay uses metadata time, never replay wall-clock time). Renames are represented by preserving identities in the new tree, then removing the old subtree. Restart reopens the Swift reference store; persistent observations survive and device-derived/nonpersistent observations are dropped. No file contents, real filesystem traversal, FSEvents transport, or SQLite schema details appear in the fixture.

Output is `{steps: [{items: [{path, resolution, protectedDescendant}], observations: [{path, resource, first, last}]}]}`. Items retain tree order; observations sort by path then resource. `resolution` uses the ordinary resolution encoding, including deadline/basis/disposition or suppression. `protectedDescendant` is an independent preflight concern: the index may retain a parent schedule but that is never permission to Trash it. Global pause likewise does not remove schedules; execution must idle while paused. Preview schedules never authorize Trash.

The Swift runner uses `IndexedCandidateEvaluation`, the reference observation/project APIs, and `RuleResolver`; its scripted preparation follows `ManagedRootIndexer.scheduledDeadline` and project-marker/noise decisions. The Rust runner injects `Clock`, `MetadataSource`, and `ObservationStore` into `scheduler::scan`. Coverage includes first-observation initialization, monotonic activity and metadata reconciliation, creation/modification/access/explicit-date bases, grace, pause/Preview/Keep, protected descendants, identity replacement, directory rename and restart, nonpersistent restart, nested-project isolation, marker loss, `.git` birth-date/fallback observations, generated directories, `.next/cache`, case-insensitive `.log` suffixes, and meaningful versus noisy replay events.

## Not yet covered

Platform path-resolution traversal and home discovery need adapter tests as described above. The scheduling fixtures cover complete scripted scan decisions, not the live watcher transport, partial/unreadable traversal recovery, batching/cancellation, deadline execution/retry backoff, or an agent run loop. These remain separate integration responsibilities; core parity is not released Linux/Windows support.
