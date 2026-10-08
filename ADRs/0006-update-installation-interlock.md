# ADR 0006 — cross-process update/Trash exclusion

Status: accepted; end-to-end update acceptance remains a release gate. Eligibility extended by [ADR 0009](0009-eddsa-only-updates-for-adhoc-builds.md).

## Problem

Replacing the application bundle while the agent is moving an item to Trash violates the update-channel safety contract. An app-side pause request alone does not drain an already-running filesystem operation. A relaunch callback alone also misses install-on-quit. Sparkle 2.9 skips `shouldProceedWithUpdate` when resuming a downloaded or already-installing update.

## Decision

Pin Sparkle and release tools to 2.9.0. Only the app links/constructs the updater. Homebrew and direct copies without a configured Ed25519 public key never construct it. Key-enabled direct builds may be ad-hoc or Developer ID signed (ADR 0009); feeds, notes and enclosures are verified before extraction. Automatic checks follow `checkForNewVersions` (on by default), and installation requires user confirmation through Update Now/the native Sparkle dialog. Automatic installations are disabled.

`TinyPruneIPC.UpdateInstallationGate` coordinates local processes through one advisory lock file and a durable JSON installation marker in TinyPrune Application Support. `TinyPruneEngine.TrashCoordinator` acquires a shared kernel lock before preflight and retains it through filesystem move and final audit. The updater obtains an exclusive nonblocking lock before offering a downloadable update. A current Trash permit rejects the update rather than canceling a move.

While holding the exclusive lock, the updater atomically writes and fsyncs a marker containing source and target **CFBundleVersion** values. The marker inhibits future Trash operations after the old app exits and its kernel lock is released. Retained downloads and installation-on-quit keep the marker. Only a safe pre-install cancellation/skip clears it; completion of a check cycle is not sufficient when an install can resume.

On startup, an eligible key-enabled direct source app can reacquire the exclusive lock before Sparkle resumes a pending download, including an ad-hoc build under ADR 0009. The held gate cannot be retargeted to a different fresh offer. An eligible target app recovers only when its bundle version matches the marker's different target version. Under the exclusive lock it unregisters/re-registers an already-enabled embedded agent to reconcile the replaced binary. It does not enable a disabled agent. Errors retain the marker. Homebrew and no-key copies cannot clear or resume the marker, regardless of signing mode.

Marker clearing releases the exclusive kernel lock while the marker still blocks cleanup, then removes the marker. A Dispatch filesystem source on the coordination directory wakes the agent scheduler after removal. This ordering avoids a wakeup observing the still-exclusive lock and subsequently sleeping forever. The observer does not require GUI run-loop delivery, poll, inspect candidate file contents, or traverse managed roots.

A blocked Trash request records a safety skip and throws a distinct transient `updateInstallationPending` error. The scheduler retains its indexed deadline and waits for a change, rather than consuming the deadline or spinning on it. Scheduler shutdown cancels the worker, stops additional due work and drains an in-flight worker before returning.

## Consequences and recovery

- Update safety does not mutate a user's global pause or rule settings.
- An interrupted/retained update can leave pruning suspended. Native Update Safety Status explains that the user must resume the update or manually install and launch its intended eligible target. A timeout or unchanged old-app launch never silently reopens cleanup.
- This coordination protocol is not implemented in frontends as a second cleanup engine; policy and deletion authorization remain in the agent.
- The release public key is nonsecret configuration; its private partner stays in the reviewer-protected update-feed Environment. Feed and note mutations happen before the final signatures.
- Prior releases without this interlock cannot safely participate. The first update-capable release must include the gate in both app and agent; there is no compatibility shim for an older unguarded agent.

## Evidence and remaining acceptance

The permanent regressions cover in-flight Trash exclusion, update inhibition/cancellation, marker survival, old/wrong-version refusal, corrupt markers, resumed target constraints, failed agent reconciliation, retained due deadlines and filesystem-event resumption. Native smoke observes actual Preview/Keep/Trash/Activity/restart outcomes on disposable files. Real Sparkle tooling accepted ephemeral signed feed/notes and rejected byte modifications; those fixture keys were not production credentials and were discarded.

A real older/newer key-enabled ad-hoc direct pair must still exercise download, cancellation, skip, resumed downloads, user-confirmed installation, install-on-quit, interruption, agent reconciliation and relaunch (ADR 0009). A Developer ID signed/notarized pair requires separate acceptance when Apple credentials become available. Ad-hoc packaging or a passing signature fixture cannot establish either end-to-end proof.

References: [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html), [pinned resumed-update implementation](https://github.com/sparkle-project/Sparkle/blob/2.9.0/Sparkle/SPUBasicUpdateDriver.m).
