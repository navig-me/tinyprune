#!/usr/bin/env python3
"""Fail when TinyPrune's version declarations disagree.

The macOS marketing version in Scripts/package-app.swift is the one source of truth. Everything else must
equal it: the Swift agent default and its tests, every Rust crate (workspace and rust/ui), both Cargo.lock
files, the Tauri config, the top released CHANGELOG heading and a RELEASES.md entry. Published feed state
(website/updates/appcast.xml) legitimately lags a prepared release, so it is only required not to be ahead
of the declared version. Stdlib only; run from anywhere:

    python3 Scripts/check-versions.py [--tag vX.Y.Z]

--tag additionally requires the declared version to equal that tag (the release workflows' sanity check).
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEMVER = r"\d+\.\d+\.\d+"
errors = []
expected = None


def read(relative):
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"{relative}: missing")
        return ""
    return path.read_text(encoding="utf-8")


def check(label, found):
    if found is None:
        errors.append(f"{label}: no version found")
    elif found != expected:
        errors.append(f"{label}: {found} (expected {expected})")


def first(pattern, text, flags=re.M):
    match = re.search(pattern, text, flags)
    return match.group(1) if match else None


def semver_key(version):
    return tuple(int(part) for part in version.split("."))


# --- source of truth ------------------------------------------------------------------------------
packager = read("Scripts/package-app.swift")
expected = first(r'let marketingVersion = .*\?\? "(' + SEMVER + r')"', packager)
if expected is None:
    sys.exit("Scripts/package-app.swift: cannot read the default marketingVersion")

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
arguments = parser.parse_args()
if arguments.tag is not None:
    if arguments.tag != f"v{expected}":
        errors.append(f"tag {arguments.tag} does not match marketing version v{expected}")

# --- Swift -------------------------------------------------------------------------------------
check("Sources/TinyPruneAgentCore/AgentRequestHandler.swift serviceVersion default",
      first(r'serviceVersion: String = "(' + SEMVER + r')"', read("Sources/TinyPruneAgentCore/AgentRequestHandler.swift")))
for test in ("AgentRequestHandlerTests", "AgentXPCTransportTests"):
    relative = f"Tests/TinyPruneAgentCoreTests/{test}.swift"
    check(f"{relative} serviceVersion assertion",
          first(r'serviceVersion == "(' + SEMVER + r')"', read(relative)))

# --- Rust --------------------------------------------------------------------------------------
manifests = sorted(p.relative_to(ROOT) for p in (ROOT / "rust").glob("*/Cargo.toml"))
if not manifests:
    errors.append("rust/*/Cargo.toml: none found")
for manifest in manifests:
    check(str(manifest), first(r'^\[package\][^\[]*?^version\s*=\s*"(' + SEMVER + r')"', read(str(manifest)), re.M | re.S))

workspace_members = set(re.findall(r'"(tinyprune-[a-z]+)"', read("rust/Cargo.toml")))
on_disk = {m.parent.name for m in manifests if m.parent.name.startswith("tinyprune-")}
if workspace_members != on_disk:
    errors.append(f"rust/Cargo.toml members {sorted(workspace_members)} differ from crates on disk {sorted(on_disk)}")

check("rust/ui/tauri.conf.json version", first(r'"version"\s*:\s*"(' + SEMVER + r')"', read("rust/ui/tauri.conf.json")))

for lock in ("rust/Cargo.lock", "rust/ui/Cargo.lock"):
    text = read(lock)
    packages = re.findall(r'\[\[package\]\]\nname = "(tinyprune-[a-z]+)"\nversion = "([^"]+)"', text)
    if not packages:
        errors.append(f"{lock}: no tinyprune packages found")
    for name, version in packages:
        check(f"{lock} {name}", version)

# --- CHANGELOG, RELEASES.md ----------------------------------------------------------------------
changelog = read("CHANGELOG.md")
headings = re.findall(r"^## (" + SEMVER + r") - (\d{4}-\d{2}-\d{2})$", changelog, re.M)
if not headings:
    errors.append("CHANGELOG.md: no '## X.Y.Z - YYYY-MM-DD' release heading")
else:
    check("CHANGELOG.md top release heading", headings[0][0])
if not re.search(r"^## Unreleased$", changelog, re.M):
    errors.append("CHANGELOG.md: no '## Unreleased' section")
elif changelog.index("## Unreleased") > changelog.index(f"## {headings[0][0]} - " if headings else "## "):
    errors.append("CHANGELOG.md: 'Unreleased' must sit above the newest release")

releases = read("RELEASES.md")
release_headings = set(re.findall(r"^## (?:v)?(" + SEMVER + r")\b", releases, re.M))
# Older releases may be recorded as table rows ("| 0.1.13 | ..." or "| [0.1.13](...)"); the current one needs its own section.
release_rows = set(re.findall(r"^\| \[?(?:v)?(" + SEMVER + r")\]?[ (|]", releases, re.M))
if expected not in release_headings:
    errors.append(f"RELEASES.md: no '## {expected}' section (every release, including prepared, withdrawn or yanked ones, is recorded there)")
for version, _ in headings:
    if version not in release_headings | release_rows:
        errors.append(f"RELEASES.md: CHANGELOG release {version} has no entry")

# --- documentation and sites ---------------------------------------------------------------------
# Public pages must not pin a release number that disagrees with the source of truth. Mentions are
# recognised as "v1.2.3" or "TinyPrune 1.2.3"; the published feed under website/updates is excluded.
pin = re.compile(r"(?:\bv|\bTinyPrune )(" + SEMVER + r")\b")
for base in ("docs", "website"):
    for path in sorted((ROOT / base).rglob("*")):
        relative = path.relative_to(ROOT)
        if (not path.is_file() or "node_modules" in path.parts or "updates" in relative.parts
                or path.suffix not in {".html", ".md", ".txt", ".js", ".json", ".xml", ".mjs"}):
            continue
        for found in pin.findall(path.read_text(encoding="utf-8", errors="replace")):
            if found != expected:
                errors.append(f"{relative}: pins release {found} (expected {expected} or no pin)")
readme = read("README.md")
for found in pin.findall(readme):
    if found != expected:
        errors.append(f"README.md: pins release {found} (expected {expected} or no pin)")

# The deployed appcast lags a prepared release by design; it must never be ahead of the declared version.
appcast = (ROOT / "website/updates/appcast.xml")
if appcast.is_file():
    published = re.findall(r"<sparkle:shortVersionString>(" + SEMVER + r")</sparkle:shortVersionString>", appcast.read_text(encoding="utf-8"))
    newest = max(published, key=semver_key) if published else None
    if newest and semver_key(newest) > semver_key(expected):
        errors.append(f"website/updates/appcast.xml lists {newest}, newer than {expected}")

if errors:
    print(f"Version check FAILED (marketing version {expected}):", file=sys.stderr)
    for line in errors:
        print(f"  - {line}", file=sys.stderr)
    sys.exit(1)
print(f"Version check passed: {expected} (Swift, {len(manifests)} Rust manifests incl. rust/ui, both lockfiles, Tauri, CHANGELOG, RELEASES.md)")
