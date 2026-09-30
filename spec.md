# TinyPrune

**Keep what matters. Let the rest expire.**

TinyPrune is a lightweight macOS application that gives files and folders lifecycle rules.

It automatically cleans Downloads, screenshots, temporary files, developer dependencies, build artifacts, caches, virtual environments, generated files, and other disposable content based on age, modification time, project inactivity, filename patterns, folder-name patterns, and explicit overrides.

TinyPrune is built around four principles:

**Simple enough to set up in minutes.**  
**Powerful enough for developers.**  
**Quiet enough to leave running forever.**  
**Safe and auditable enough to trust with files.**

TinyPrune runs locally on the Mac.

It does not require an account.

It does not need to inspect file contents for normal operation.

---

# 1. Product concept

TinyPrune adds a missing filesystem concept:

> **Files can have a lifetime.**

Examples:

```text id="fbb211"
Downloads
→ Trash files after 14 days

Screenshots
→ Trash files after 7 days

~/Developer/**
→ Trash node_modules after 30 days of project inactivity

~/Developer/**
→ Trash .venv after 45 days of project inactivity

~/Developer/**
→ Trash __pycache__ after 7 days without modification

~/Projects/archive/**
→ Never delete automatically
```

Individual files and folders can override inherited rules.

Example:

```text id="997d72"
Downloads                         14 days
├── Chrome.dmg                    inherits → 14 days
├── screenshot.png               override → tonight
├── tax-return.pdf               KEEP
└── temporary/
    └── export.zip               inherits → 14 days
```

TinyPrune should feel like:

> **TTL for your filesystem.**

Not:

> “another Mac cleaner.”

---

# 2. What TinyPrune is not

TinyPrune should avoid becoming a generic system optimizer.

Do not add:

- duplicate finder
- RAM cleaner
- antivirus
- browser cleaner
- photo optimizer
- storage heatmaps
- cloud storage
- AI organization
- generic productivity features
- subscription-dependent functionality

The core responsibility is:

> Determine when disposable files or folders have reached the end of their useful life and move them safely to Trash.

---

# 3. Core rule model

Every rule answers four questions:

```text id="08e326"
WHERE?
WHAT?
WHEN?
ACTION?
```

Example:

```text id="a6afca"
WHERE
~/Developer/**

WHAT
Folder named node_modules

WHEN
Project inactive for 30 days

ACTION
Move entire folder to Trash
```

Another:

```text id="906c51"
WHERE
~/Downloads

WHAT
Files matching *.dmg

WHEN
7 days after entering Downloads

ACTION
Move file to Trash
```

The rule engine can be sophisticated internally.

The UI should remain simple.

---

# 4. Supported matching

Rules may match based on:

## Scope

Examples:

```text id="889cdf"
~/Downloads
~/Developer
~/Developer/**
~/Desktop/Screenshots
```

## Item type

```text id="c60118"
File
Folder
File + Folder
```

## Exact names

Examples:

```text id="0924b9"
node_modules
.venv
venv
__pycache__
dist
build
target
```

## Glob patterns

Examples:

```text id="42446d"
*.dmg
*.zip
*.log
**/node_modules
**/.venv
**/.cache/**
```

Regex may exist only in Advanced mode.

Glob patterns should be preferred.

---

# 5. Rule structure

Conceptual rule:

```yaml id="87d6a5"
id: developer-node-modules

scope:
  path: ~/Developer
  recursive: true

match:
  type: directory
  names:
    - node_modules

expiry:
  basis: project_activity
  after: 30d

action:
  type: trash_item

safety:
  respect_keep_overrides: true
```

---

# 6. Rule precedence

Rules must resolve predictably.

Recommended order:

```text id="a0a330"
Explicit Keep protecting subtree
        ↓
Explicit item-specific rule
        ↓
Exact path exception
        ↓
Closest folder-specific rule
        ↓
Pattern rule inside closest scope
        ↓
Parent folder rules
        ↓
Template/global rule
        ↓
No rule → do nothing
```

No ambiguous resolution.

No silent guessing.

---

# 7. Overrides

Every item supports:

```text id="31a301"
Inherit
Keep
Custom
```

## Inherit

Use the nearest applicable rule.

## Keep

Protect the item.

For folders:

```text id="049470"
Protect this folder only

or

Protect folder + descendants
```

Example:

```text id="a160ae"
Scout/
Protect folder only

Scout/node_modules/
still eligible for cleanup
```

Versus:

```text id="08090a"
legacy-production/
Protect descendants

legacy-production/node_modules/
protected
```

## Custom

Examples:

```text id="262bde"
Tonight
Tomorrow
3 days
7 days
30 days
Custom date
Never
Custom inactivity rule
```

---

# 8. Folder actions

Folder rules must support three distinct actions.

## Trash entire folder

Best for:

```text id="50923e"
node_modules
.venv
dist
build
target
```

## Empty folder contents

Best for:

```text id="0e99e8"
Temporary/
Screenshots/
Exports/
Cache/
```

The folder itself remains.

## Trash matching children

Example:

```text id="1f1c4b"
Downloads

*.dmg → 7 days
*.zip → 14 days
other files untouched
```

---

# 9. Expiry bases

Rules may use:

```text id="269e11"
Created
Last modified
Added to folder
Last observed activity
Last accessed
Project activity
Explicit date
```

## Created

Filesystem creation timestamp.

## Last modified

Reliable general-purpose option.

## Added to folder

TinyPrune records when it first observes the item in the managed folder.

Useful for Downloads.

## Last observed activity

TinyPrune tracks relevant filesystem changes itself.

Useful when filesystem access metadata is unreliable.

## Last accessed

Advanced option.

May not be reliable on every filesystem.

TinyPrune should recommend Modified or Observed Activity when appropriate.

## Project activity

Developer-specific higher-level measure.

---

# 10. Project detection

TinyPrune should automatically detect software project roots from markers such as:

```text id="722240"
.git/
package.json
pyproject.toml
requirements.txt
Cargo.toml
go.mod
Gemfile
pom.xml
build.gradle
composer.json
```

Example:

```text id="34c376"
~/Developer/example/
├── .git/
├── package.json
├── src/
└── node_modules/
```

TinyPrune detects:

```text id="37635e"
Project root:
~/Developer/example
```

---

# 11. Project inactivity

Instead of evaluating when `node_modules` itself changed, TinyPrune can evaluate whether the surrounding project has been active.

Example:

```text id="cd17fd"
node_modules
→ Trash after project inactive for 30 days
```

This prevents deleting dependencies from actively developed projects.

---

# 12. Meaningful project activity

TinyPrune should ignore noisy generated changes.

Ignore by default:

```text id="1a4b5e"
node_modules/**
.venv/**
__pycache__/**
.pytest_cache/**
.next/cache/**
.cache/**
dist/**
build/**
target/**
*.log
```

Meaningful activity can include:

```text id="d747f2"
source files
application files
configuration
manifest files
documentation
user-edited files
```

No source-code analysis is required.

Only filesystem events.

---

# 13. Templates

TinyPrune should ship with polished templates.

## Developer Cleanup

```text id="3e3347"
node_modules
30 days project inactivity
Trash folder

.venv / venv
45 days project inactivity
Trash folder

__pycache__
7 days unchanged
Trash folder

.pytest_cache
7 days unchanged
Trash folder

.next/cache
14 days inactivity
Trash folder

dist / build
30 days project inactivity
Trash folder

target
30 days project inactivity
Trash folder
```

## Downloads

```text id="045946"
DMG installers        7 days
ZIP archives         14 days
Other downloads      30 days
```

## Screenshots

```text id="47ec2f"
Screenshots
7 days after creation
```

## Temporary Workspace

```text id="79544b"
Anything placed in chosen folder
→ expires after chosen duration
```

## Build Artifacts

```text id="d5865b"
dist
build
target
coverage
.cache
```

Templates should always create editable normal rules.

No hidden magic.

---

# 14. Onboarding

Step 1:

```text id="969770"
Files don’t all need to live forever.
```

Explain:

> TinyPrune quietly moves files to Trash once they are no longer useful.

Step 2:

```text id="2775f6"
What would you like to keep tidy?

Downloads
Screenshots
Developer Junk
Choose a Folder
```

Step 3:

```text id="0ef32e"
Always recoverable.
```

Explain:

> TinyPrune moves items to Trash. It does not permanently delete them.

Enable:

```text id="cc79dd"
Start broad rules in Preview mode
```

---

# 15. Main navigation

```text id="2b02c3"
Overview
Rules
Upcoming
Activity
Templates
Settings
```

No v1 automation or agent-related screens.

---

# 16. Overview

Overview should be intentionally calm.

Top:

```text id="2a765d"
Everything is tidy.

TinyPrune is running quietly.
```

Then:

## Managed Places

```text id="baf582"
Downloads
14-day cleanup

Developer
Smart developer cleanup

Screenshots
7 days

Temporary Workspace
3 days
```

Then:

## Next to Prune

```text id="30e116"
Chrome.dmg
Today

old-project/node_modules
Tomorrow

export.zip
Friday
```

Avoid dashboard charts and giant KPIs.

---

# 17. Rules screen

Rules should read as natural-language statements.

Example:

```text id="13c50f"
Old Node Modules

When a folder named node_modules is inside
~/Developer/** and the project has been inactive
for 30 days, move the folder to Trash.
```

Show:

```text id="85633a"
Active
43 matches
8 eligible
```

Actions:

```text id="23bce9"
Edit
Preview Matches
Pause
Duplicate
Delete
```

---

# 18. Rule editor

Use clear sections:

```text id="2772f1"
WHERE
~/Developer/**

WHAT
Folder named node_modules

WHEN
Project inactive for 30 days

THEN
Move entire folder to Trash

EXCEPT
~/Developer/Scout
```

Impact preview:

```text id="cfd479"
43 matches
8 would be pruned now
6.4 GB estimated
```

Actions:

```text id="fbdfb3"
Cancel
Save as Preview
Activate Rule
```

Preview should be emphasized for broad rules.

---

# 19. Finder integration

Right-click:

```text id="e95931"
TinyPrune

Keep
Expire Tonight
Tomorrow
7 Days
30 Days
Custom…
Use Folder Rules
Why will this expire?
```

Folders additionally:

```text id="0d1317"
Set Folder Lifetime…
Protect Folder…
Create Rule…
```

Finder should be a primary interaction surface.

---

# 20. Menu bar

Optional compact menu:

```text id="9038d1"
TinyPrune

Running quietly

Upcoming
17 items

Next prune
Chrome.dmg · 6:40 PM

Pause
    1 hour
    Today
    Until tomorrow

Open TinyPrune
```

---

# 21. Upcoming

Group items by:

```text id="39bcaa"
Today
Tomorrow
Next 7 Days
Later
```

Rows show:

```text id="21e993"
name
path
expiry time
matched rule
size
state
```

Possible states:

```text id="36f67d"
Inherited
Custom
Protected
Preview
```

---

# 22. Why inspector

Every candidate item supports:

```text id="69e1e4"
Why will this be pruned?
```

Example:

```text id="b1a88c"
~/Developer/old-project/node_modules

Scheduled:
Tomorrow · 5 PM

Matched rule:
Old Node Modules

Reason:
Project inactive for 41 days

Project root:
~/Developer/old-project

Overrides:
None
```

Actions:

```text id="c65383"
Keep
+7 days
+30 days
Open Rule
```

---

# 23. Activity

Activity is a chronological audit log.

Events include:

```text id="b2fd47"
Rule created
Rule edited
Rule paused
Rule deleted
File protected
File unprotected
Expiry changed
Moved to Trash
Trash failed
Permission denied
Preview match
Rule skipped due to protection
```

Example:

```text id="a9270e"
10:42 AM

Moved Chrome.dmg to Trash

Downloads
Installer rule · 7 days
```

Audit history remains local.

---

# 24. Preview mode

Every rule supports:

```text id="20e77f"
Active
Preview
Paused
```

Preview performs all matching and scheduling but never moves anything to Trash.

Example:

```text id="6c90a4"
Developer Cleanup has been previewing for 7 days.

Would prune:

14 node_modules
4 virtual environments
8 build directories

Estimated:
11.4 GB
```

Preview should be the default for broad developer cleanup.

---

# 25. Safety model

Normal deletion always means:

```text id="1ee8f9"
Move to Trash
```

No permanent deletion in v1.

Before any action TinyPrune rechecks:

```text id="de2170"
Does item still exist?

Is it still the same filesystem object?

Does rule still apply?

Has item gained Keep?

Has ancestor become protected?

Has deadline changed?

Is TinyPrune paused?

Is volume available?
```

Only then move it.

---

# 26. Protected descendants

If a folder is due to be trashed but contains a protected descendant:

```text id="e1dc45"
Temporary Project/
├── cache/
└── contract.pdf       KEEP
```

TinyPrune must not trash the entire parent.

It may remove eligible children while retaining protected content.

Safety overrides convenience.

---

# 27. Grace periods

Rules may optionally define:

```text id="70cdd2"
Grace period
```

Example:

```text id="a54c62"
Expires after:
30 days inactivity

Grace:
6 hours
```

The item becomes eligible first, then moves to Trash only after grace completes.

---

# 28. Pause controls

Support:

```text id="bead77"
Global pause
Folder pause
Rule pause
```

Options:

```text id="f32976"
1 hour
Today
Until tomorrow
Until custom date
Indefinitely
```

While paused:

- filesystem events may still be tracked
- destructive actions do not occur

---

# 29. Filesystem architecture

TinyPrune must not continuously crawl managed folders.

Bad:

```text id="021780"
Every minute:
scan everything
stat every file
evaluate every rule
```

Good:

```text id="d922a8"
filesystem changes
→ update affected state

deadline reached
→ inspect affected candidate

rule changed
→ recalculate affected scope
```

---

# 30. Filesystem events

TinyPrune should use macOS filesystem events for managed directory trees.

Conceptually:

```text id="1773a2"
Filesystem changes
        ↓
TinyPrune Agent
        ↓
Identify affected items/project
        ↓
Update activity/deadline
        ↓
Sleep
```

When nothing happens, TinyPrune should consume almost no CPU.

---

# 31. Deadline scheduling

Once a deadline resolves:

```text id="bec98a"
Chrome.dmg
expires Oct 7 · 14:00
```

TinyPrune stores that deadline.

It does not repeatedly reevaluate the item.

Database:

```text id="089936"
Chrome.dmg          Oct 7 · 14:00
foo.zip             Oct 9 · 11:00
node_modules        Oct 30 · 09:00
```

The scheduler primarily needs to know:

```text id="994736"
What expires next?
```

---

# 32. SQLite index

Use SQLite for operational state.

Suggested tables:

```text id="ad7e32"
managed_roots
rules
rule_scopes
item_overrides
projects
deadlines
audit_events
settings
```

Deadline index:

```sql id="faee12"
CREATE INDEX deadline_idx
ON deadlines(expires_at);
```

---

# 33. Object identity

Path must not be the sole identity.

Where available store:

```text id="4460f1"
volume identity
filesystem item identity
path hint
```

This makes rename and move handling safer.

---

# 34. Extended attributes

Explicit per-item policy may also be stored as filesystem metadata.

Examples:

```text id="f86543"
com.tinyprune.policy
com.tinyprune.expiry
com.tinyprune.keep
```

Do not write metadata to every inherited child.

Example:

```text id="32bc83"
Downloads → 14 days
```

with 50,000 files should not create 50,000 metadata writes.

Only explicit overrides need item-specific metadata.

---

# 35. Hybrid metadata

Use:

```text id="b06285"
SQLite
+
filesystem metadata
```

SQLite handles:

- deadlines
- fast querying
- audit history
- project activity
- operational state

Extended attributes help:

- explicit rule persistence
- rename/move continuity
- index recovery

Neither layer is blindly trusted.

---

# 36. Initial indexing

Adding a managed folder requires one initial enumeration.

Must be streaming.

Bad:

```text id="6a3bf9"
load every file into memory
```

Good:

```text id="e8c221"
enumerate batch
resolve
persist
release
continue
```

Memory usage should remain roughly constant even for huge trees.

---

# 37. Folder size calculation

Do not calculate recursive sizes continuously.

Only calculate folder sizes when:

```text id="921673"
user asks
preview needs estimate
rule uses size
UI explicitly requires it
```

Background performance matters more than continuously accurate disk-space metrics.

---

# 38. Resource targets

Engineering goals:

| Metric | Target |
|---|---:|
| Idle CPU | effectively 0% |
| Background memory | <20–30 MB target |
| GUI memory | <80 MB preferred |
| GUI closed | UI process can terminate |
| Idle disk writes | minimal |
| File-content reads | zero normally |
| Network | zero required |
| Recursive scanning | initial/recovery only |
| 100k managed entries | routine |
| 1M managed entries | supported |

The app should be forgettably lightweight.

---

# 39. Process architecture

Recommended:

```text id="26f1f3"
TinyPrune.app
SwiftUI / AppKit
        │
        │ XPC
        ▼
TinyPrune Agent
        │
        ├── Filesystem Events
        ├── Rule Engine
        ├── Deadline Scheduler
        ├── Project Activity Resolver
        ├── Safety Engine
        └── Trash Executor
        │
        ▼
SQLite
```

Additional frontends:

```text id="43fa06"
Finder Extension
CLI
```

All use the same rule engine.

---

# 40. CLI

TinyPrune should ship with:

```bash id="77763a"
tinyprune
```

Examples:

```bash id="d35076"
tinyprune keep invoice.pdf

tinyprune expire video.mov 7d

tinyprune expire screenshot.png tonight

tinyprune inherit foo.zip

tinyprune why node_modules

tinyprune upcoming

tinyprune rules

tinyprune preview developer-cleanup
```

Machine-readable output:

```bash id="391a6d"
tinyprune rules --json
tinyprune upcoming --json
tinyprune status --json
```

The CLI should talk to the main background agent rather than implementing its own cleanup engine.

In v1, the CLI is for direct user scripting and inspection only.

Agentic automation is deferred to v2.

---

# 41. Config as code

Optional config file:

```text id="7aa804"
.tinyprune.yml
```

Example:

```yaml id="9a2883"
version: 1

roots:
  - ~/Developer

rules:
  - name: Node dependencies
    match:
      directories:
        - node_modules
    expiry:
      after: 30d
      since: project_activity
    action: trash

  - name: Python environments
    match:
      directories:
        - .venv
        - venv
    expiry:
      after: 45d
      since: project_activity
    action: trash

exceptions:
  - path: ~/Developer/legacy-production
    protect: descendants
```

Commands:

```bash id="58fb04"
tinyprune config validate tinyprune.yml

tinyprune config preview tinyprune.yml

tinyprune config apply tinyprune.yml
```

---

# 42. Installation

Primary channels:

## DMG

Website:

```text id="ce98fd"
tinyprune.com
```

Download:

```text id="87545d"
TinyPrune.dmg
```

Flow:

```text id="7e93fc"
Open DMG
Drag to Applications
Launch
```

The app must be signed and notarized.

---

# 43. Homebrew

Support:

```bash id="688b52"
brew install --cask tinyprune
```

The cask should ideally install:

```text id="5ad302"
TinyPrune.app
tinyprune CLI
```

The app may additionally offer:

```text id="127c8c"
Install Command Line Tool
```

from Settings.

---

# 44. Updates

DMG installs should support normal signed in-app updates.

Homebrew installs should update through Homebrew.

TinyPrune should avoid interfering with the package manager.

---

# 45. Permissions

Request the smallest filesystem access practical.

Example:

```text id="0df392"
Downloads
Developer
Screenshots
```

The user should be able to view and remove allowed locations.

Avoid requiring broad Full Disk Access unless absolutely necessary.

---

# 46. Dangerous-root protection

TinyPrune should reject or strongly guard obvious dangerous scopes.

Examples:

```text id="3767f5"
/
System
system Library locations
Applications
```

Very broad roots should start in Preview.

Example:

```text id="126d16"
You are about to manage your entire home folder.

TinyPrune recommends selecting specific locations.

[ Cancel ]
[ Continue in Preview ]
```

---

# 47. Settings

Keep Settings compact.

## General

```text id="d9e9ed"
Launch at login
Show menu bar icon
Notifications
```

## Safety

```text id="e1d779"
Default grace period
Protect hidden files
Preview broad rules by default
```

## Storage

```text id="e71d33"
Indexed items
Database size
Activity history retention
Rebuild Index
Export Activity Log
```

## Developer

```text id="663f31"
Install CLI
Export configuration
Import configuration
```

No agentic controls in v1.

---

# 48. Notifications

Default:

```text id="098a22"
Only notify when attention is needed.
```

Examples:

```text id="ec7e9d"
Folder access lost
External volume unavailable
Cleanup blocked
Rule failed
Rule unexpectedly broadened
```

Avoid noisy “saved space” notifications by default.

---

# 49. Privacy

Core principle:

> TinyPrune does not need to know what your files contain.

TinyPrune normally needs:

```text id="dcb470"
path
name
type
timestamps
filesystem identity
size when required
rule
expiry
activity metadata
```

File contents are not required for ordinary cleanup.

No account.

No cloud dependency.

No network required for the core product.

---

# 50. External drives

Support priority:

```text id="94dcc4"
Internal APFS
External APFS
External HFS+
```

Removable drive rules should simply remain dormant when the drive is disconnected.

No repeated polling.

---

# 51. Cloud folders

Cloud-managed roots such as:

```text id="76d0f1"
iCloud Drive
Dropbox
Google Drive
OneDrive
```

should initially be treated cautiously because placeholder files and metadata behavior differ.

TinyPrune's SQLite state should remain authoritative where filesystem metadata is unreliable.

---

# 52. Failure recovery

If the database must be rebuilt:

```text id="72ecff"
managed roots
+
rule configuration
+
filesystem metadata
```

should allow reconstruction.

Inherited rules can be re-derived.

Explicit metadata can restore overrides where available.

---

# 53. Database maintenance

TinyPrune may periodically:

```text id="8e47d4"
remove stale identities
remove obsolete deadlines
compact old audit metadata
vacuum only when worthwhile
```

Avoid unnecessary background writes.

---

# 54. V1 scope

A strong v1 contains:

1. Managed folders
2. Folder lifetimes
3. File/folder name matching
4. Glob patterns
5. Created / modified / added / observed activity expiry
6. Project detection
7. Project inactivity rules
8. Developer cleanup template
9. Downloads template
10. Screenshots template
11. Temporary workspace template
12. Build artifact template
13. Keep / Inherit / Custom overrides
14. Protect folder-only vs descendants
15. Trash folder / contents / matching children
16. Finder integration
17. Menu bar
18. Upcoming screen
19. Why inspector
20. Preview mode
21. Activity log
22. Pause controls
23. SQLite index
24. Event-driven monitoring
25. CLI
26. JSON CLI output
27. Config as code
28. DMG install
29. Homebrew cask
30. Signed updates

---

# 55. V2 scope

Agentic functionality is explicitly deferred to v2.

Potential v2 features:

```text id="ee8527"
MCP server
Local API
Local LLM integration
Agent permissions
Agent approvals
Natural-language rule generation
Structured rule proposals
Agent audit identity
Shortcuts automation
Raycast integration
Alfred integration
IDE activity integrations
Shell activity integration
```

These should sit on top of the existing deterministic v1 rule engine.

No v1 architecture should require an LLM.

---

# 56. V2 agent principle

When eventually added:

> Agents propose and manipulate deterministic TinyPrune rules.

Agents should never directly decide which files to delete without TinyPrune's rule and safety engine.

The v1 architecture should therefore expose a clean internal rule model so agentic interfaces can be added later without redesigning the filesystem layer.

---

# 57. Example developer workflow

Install:

```bash id="a4a70f"
brew install --cask tinyprune
```

Enable:

```text id="524627"
Developer Cleanup
```

TinyPrune proposes:

```text id="3a72ca"
node_modules
30 days project inactivity

.venv
45 days project inactivity

__pycache__
7 days unchanged

dist / build
30 days inactivity
```

The rules begin in Preview.

One week later:

```text id="57844b"
Would prune:

8 node_modules
3 virtual environments
14 cache directories
```

User reviews matches.

Then activates.

From then on TinyPrune runs quietly.

---

# 58. Example normal-user workflow

User enables Downloads.

TinyPrune creates:

```text id="fc437d"
Installers
7 days

Archives
14 days

Other Downloads
30 days
```

User right-clicks:

```text id="65ac73"
passport-scan.pdf
→ TinyPrune
→ Keep
```

No further setup required.

---

# 59. Core performance invariant

> Complexity should scale with filesystem changes, not total filesystem size.

A million indexed files should not result in repeatedly scanning a million files.

Instead:

```text id="e256ea"
filesystem event
→ update affected state

deadline
→ inspect candidate

rule edit
→ recalculate affected scope
```

Then sleep.

---

# 60. Core safety invariant

> Re-evaluate current policy immediately before moving anything to Trash.

The database schedules work.

It does not itself authorize deletion.

---

# 61. Core UX invariant

For every scheduled action, TinyPrune should be able to answer:

```text id="8b6bb3"
What?
When?
Why?
Which rule?
Which override?
How do I stop it?
```

If the app cannot answer those clearly, it should not act.

---

# 62. Brand

## Name

**TinyPrune**

## Domain

**tinyprune.com**

## Tagline

**Keep what matters. Let the rest expire.**

## Developer phrase

**TTL for your filesystem.**

---

# 63. Visual identity

Use a small prune fruit mark:

```text id="04a8ad"
slightly asymmetric prune shape
tiny stem
small leaf
subtle clipped detail
rich plum tone
simple silhouette
```

Cute, but not childish.

It should work at:

```text id="7e05c5"
16 px
32 px
128 px
app icon
menu bar
website favicon
```

---

# 64. Product positioning

For normal users:

> **Automatic cleanup for temporary files.**

For developers:

> **TTL and lifecycle rules for your filesystem.**

Core positioning:

> TinyPrune quietly removes files and folders that have outlived their usefulness, while keeping every decision visible, reversible, and under your control.

---

# 65. Final product principle

TinyPrune should be sophisticated underneath and effortless on the surface.

A normal user thinks:

```text id="e853a7"
Downloads → 14 days
```

A developer thinks:

```text id="46994a"
node_modules → 30 days project inactivity
```

TinyPrune translates both into the same safe, deterministic, low-overhead lifecycle engine.

That is the v1 product.
