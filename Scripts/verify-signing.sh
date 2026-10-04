#!/bin/bash
# Verifies the TinyPrune signing design (ADR 0004) for a packaged .app.
#
#   Scripts/verify-signing.sh [--release [--pre-notarize]] path/to/TinyPrune.app
#
# Default (dev) mode accepts ad-hoc signatures: all Mach-O files must then share one
# identity class (ad-hoc) and the app/agent/CLI must share the app bundle identifier.
# --release additionally requires a single non-empty Team ID across every Mach-O, hardened
# runtime and a secure timestamp everywhere, a Gatekeeper assessment and a stapled ticket.
# TINYPRUNE_EXPECTED_TEAM_ID (optional) pins the Team ID in --release mode.
# --pre-notarize (with --release) skips only the Gatekeeper/stapler checks, which cannot
# pass until Apple has notarized the app.
set -uo pipefail

release=0
notarized=1
if [[ "${1:-}" == "--release" ]]; then
  release=1; shift
  if [[ "${1:-}" == "--pre-notarize" ]]; then notarized=0; shift; fi
fi
app="${1:-}"
if [[ -z "$app" || ! -d "$app/Contents" ]]; then
  echo "usage: $0 [--release] path/to/TinyPrune.app" >&2
  exit 2
fi
app="${app%/}"

agent_service="com.navig-me.tinyprune.agent"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
check() { # description, command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }
detail() { codesign -dvv "$1" 2>&1; } # key=value lines on stderr, merged
field() { detail "$1" | sed -n "s/^$2=//p" | head -1; }
entitlements_xml() { codesign -d --entitlements :- "$1" 2>/dev/null; }
entitlement_keys() { entitlements_xml "$1" | grep -o '<key>[^<]*</key>' | sed 's/<key>\(.*\)<\/key>/\1/'; }

app_id="$(bundle_id "$app")"
main_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
appex="$app/Contents/PlugIns/TinyPruneFinderExtension.appex"
appex_id="$(bundle_id "$appex")"
echo "App: $app (bundle id ${app_id:-?}, mode: $([[ $release == 1 ]] && echo release || echo development))"

[[ -n "$app_id" ]] || fail "app bundle identifier readable"
[[ -d "$appex" ]] || fail "Finder extension present at $appex"

# --- Seal integrity -------------------------------------------------------------------
check "codesign --verify --deep --strict" codesign --verify --deep --strict "$app"

# --- Every Mach-O: team / identity class, hardened runtime, timestamp ------------------
machos=()
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'Mach-O'; then machos+=("$file"); fi
done < <(find "$app" -type f -print0)
[[ ${#machos[@]} -gt 0 ]] && pass "found ${#machos[@]} Mach-O files" || fail "no Mach-O files found"

teams=()
for file in "${machos[@]}"; do
  rel="${file#"$app"/}"
  info="$(detail "$file")"
  team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  flags="$(printf '%s\n' "$info" | sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\2/p' | head -1)"
  if ! printf '%s\n' "$info" | grep -q '^Identifier='; then fail "$rel is signed"; continue; fi
  teams+=("$team")
  adhoc=0; [[ "$flags" == *adhoc* ]] && adhoc=1
  if [[ $release == 1 ]]; then
    [[ "$flags" == *runtime* ]] && pass "$rel hardened runtime" || fail "$rel hardened runtime flag missing (flags: $flags)"
    printf '%s\n' "$info" | grep -q '^Timestamp=' && pass "$rel secure timestamp" || fail "$rel secure timestamp missing"
    [[ $adhoc == 0 ]] && pass "$rel not ad-hoc" || fail "$rel is ad-hoc signed"
    [[ -n "$team" && "$team" != "not set" ]] && pass "$rel Team ID $team" || fail "$rel has no Team ID"
  else
    [[ "$flags" == *runtime* ]] && pass "$rel hardened runtime" || echo "note: $rel lacks hardened runtime (required for release)"
  fi
done

unique_teams="$(printf '%s\n' "${teams[@]}" | sort -u | wc -l | tr -d ' ')"
[[ "$unique_teams" == "1" ]] && pass "all Mach-O files share one Team ID / identity class (${teams[0]})" \
  || fail "Mach-O files carry $unique_teams distinct Team IDs: $(printf '%s ' "${teams[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

if [[ $release == 1 && -n "${TINYPRUNE_EXPECTED_TEAM_ID:-}" ]]; then
  [[ "${teams[0]:-}" == "$TINYPRUNE_EXPECTED_TEAM_ID" ]] && pass "Team ID matches TINYPRUNE_EXPECTED_TEAM_ID" \
    || fail "Team ID '${teams[0]:-}' != expected '$TINYPRUNE_EXPECTED_TEAM_ID'"
fi

# --- Identifier policy: app, agent, CLI share the app bundle id -----------------------
for name in "$main_exec" TinyPruneAgent tinyprune; do
  path="$app/Contents/MacOS/$name"
  if [[ ! -f "$path" ]]; then fail "$name present"; continue; fi
  id="$(field "$path" Identifier)"
  [[ "$id" == "$app_id" ]] && pass "$name identifier == $app_id" || fail "$name identifier '$id' != app bundle id '$app_id'"
done
appex_binary="$appex/Contents/MacOS/TinyPruneFinderExtension"
appex_signed_id="$(field "$appex" Identifier)"
[[ "$appex_signed_id" == "$appex_id" && -n "$appex_id" ]] && pass "appex identifier == its bundle id ($appex_id)" \
  || fail "appex identifier '$appex_signed_id' != its bundle id '$appex_id'"
[[ "$appex_id" != "$app_id" ]] && pass "appex bundle id differs from app id" || fail "appex bundle id must differ from the app"

# --- Entitlements -----------------------------------------------------------------------
ent="$(entitlements_xml "$appex")"
printf '%s' "$ent" | grep -A1 '<key>com.apple.security.app-sandbox</key>' | grep -q '<true/>' \
  && pass "appex App Sandbox enabled" || fail "appex lacks com.apple.security.app-sandbox"
printf '%s' "$ent" | grep -A3 '<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>' | grep -q "<string>$agent_service</string>" \
  && pass "appex mach-lookup exception for $agent_service" || fail "appex mach-lookup exception for $agent_service missing"
extras="$(entitlement_keys "$appex" | grep -v -x -e com.apple.security.app-sandbox -e com.apple.security.temporary-exception.mach-lookup.global-name | tr '\n' ' ')"
[[ -z "$extras" ]] && pass "appex has no other entitlements (no network)" || fail "appex has unexpected entitlements: $extras"
agent_exceptions="$(entitlements_xml "$appex" | grep -c '<string>' || true)"
[[ "$agent_exceptions" == "1" ]] && pass "appex mach-lookup list contains only the agent service" || fail "appex mach-lookup list has $agent_exceptions entries"

for target in "$app" "$app/Contents/MacOS/TinyPruneAgent" "$app/Contents/MacOS/tinyprune"; do
  e="$(entitlements_xml "$target")"
  if printf '%s' "$e" | grep -q 'get-task-allow'; then
    [[ $release == 1 ]] && fail "${target#"$app"/} carries get-task-allow" || echo "note: ${target#"$app"/} carries get-task-allow (debug)"
  fi
  if printf '%s' "$e" | grep -q 'app-sandbox'; then fail "${target#"$app"/} must not be sandboxed (agent needs bookmarks/Trash/FSEvents)"; fi
  if [[ $release == 1 ]] && printf '%s' "$e" | grep -q 'disable-library-validation'; then
    fail "${target#"$app"/} disables library validation in a release"
  fi
done

# --- Sparkle isolation (PLAN.md): only the app may link or embed Sparkle ----------------
for target in "$app/Contents/MacOS/TinyPruneAgent" "$app/Contents/MacOS/tinyprune" "$appex_binary"; do
  if otool -L "$target" 2>/dev/null | grep -qi sparkle; then fail "${target#"$app"/} links Sparkle"; else pass "${target#"$app"/} does not link Sparkle"; fi
done
if [[ -e "$appex/Contents/Frameworks/Sparkle.framework" ]]; then fail "Sparkle embedded in the Finder extension"; fi
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$sparkle" ]] && pass "Sparkle embedded in application" || fail "Sparkle framework missing"
otool -L "$app/Contents/MacOS/$main_exec" | grep -q '@rpath/Sparkle.framework' \
  && pass "application links Sparkle" || fail "application does not link embedded Sparkle"
check "embedded Sparkle signature" codesign --verify --deep --strict "$sparkle"
for helper in Autoupdate Updater.app XPCServices/Downloader.xpc XPCServices/Installer.xpc; do
  [[ -e "$sparkle/Versions/B/$helper" ]] && pass "Sparkle $helper present" || fail "Sparkle $helper missing"
done
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null; }
channel="$(plist_value TinyPruneDistribution)"
enabled="$(plist_value TinyPruneUpdatesEnabled)"
[[ "$channel" == direct || "$channel" == homebrew ]] || fail "unknown update distribution"
[[ "$(plist_value SUFeedURL)" == https://tinyprune.com/updates/appcast.xml ]] || fail "unexpected direct update feed URL"
[[ "$(plist_value SURequireSignedFeed)" == true && "$(plist_value SUVerifyUpdateBeforeExtraction)" == true ]] \
  && pass "signed feed and pre-extraction verification required" || fail "update cryptographic verification not required"
[[ "$(plist_value SUSignedFeedFailureExpirationInterval)" == 0 ]] || fail "signed feed validation must fail closed"
[[ "$(plist_value SUAllowsAutomaticUpdates)" == false && "$(plist_value SUAutomaticallyUpdate)" == false ]] \
  && pass "automatic installations disabled" || fail "automatic installation policy mismatch"
if [[ "$channel" == homebrew || "$(plist_value TinyPruneSigning)" == ad-hoc ]]; then
  [[ "$enabled" == false && "$(plist_value SUEnableAutomaticChecks)" == false ]] \
    && pass "Homebrew/development updater disabled" || fail "Homebrew/development updater enabled"
fi
if [[ "$enabled" == true ]]; then
  [[ "$channel" == direct && "$(plist_value TinyPruneSigning)" == developer-id ]] || fail "updater enabled outside signed direct channel"
  [[ "$(plist_value SUPublicEDKey)" != "" && "$(plist_value SUEnableAutomaticChecks)" == true ]] \
    && pass "enabled updater has public key and checks" || fail "enabled updater lacks public key/check policy"
else
  [[ "$(plist_value SUEnableAutomaticChecks)" == false ]] || fail "disabled updater has automatic checks"
fi

# --- Gatekeeper + notarization (release only) -------------------------------------------
if [[ $release == 1 && $notarized == 1 ]]; then
  check "spctl --assess --type execute" spctl --assess --type execute -vv "$app"
  check "stapler validate" xcrun stapler validate "$app"
else
  echo "note: spctl/stapler checks skipped ($([[ $release == 1 ]] && echo pre-notarization || echo development) mode)"
fi

echo
if [[ $failures -eq 0 ]]; then echo "verify-signing: PASS"; else echo "verify-signing: $failures failure(s)"; exit 1; fi
