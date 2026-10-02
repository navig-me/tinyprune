#!/bin/bash
# Build a distinct bundle: never disable direct-channel checks by modifying a cask install.
set -euo pipefail
export TINYPRUNE_DISTRIBUTION=homebrew
swift Scripts/package-app.swift
app=.build/package/TinyPrune.app
if [[ "$SIGNING_MODE" == signed ]]; then
  Scripts/verify-signing.sh --release --pre-notarize "$app"
  ditto -c -k --keepParent "$app" "$RUNNER_TEMP/homebrew-app.zip"
  xcrun notarytool submit "$RUNNER_TEMP/homebrew-app.zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --output-format json > "$RUNNER_TEMP/homebrew-app-notary.json"
  jq -e '.status == "Accepted"' "$RUNNER_TEMP/homebrew-app-notary.json"
  xcrun stapler staple "$app"
  Scripts/verify-signing.sh --release "$app"
else
  Scripts/verify-signing.sh "$app"
fi
stage="$RUNNER_TEMP/homebrew-stage"
mkdir -p "$stage"
ditto "$app" "$stage/TinyPrune.app"
ln -s /Applications "$stage/Applications"
dmg="$RUNNER_TEMP/TinyPrune-${RELEASE_TAG#v}-homebrew.dmg"
hdiutil create -volname TinyPrune -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
if [[ "$SIGNING_MODE" == signed ]]; then
  codesign --force --sign "$TINYPRUNE_SIGN_IDENTITY" --timestamp "$dmg"
  codesign --verify --strict "$dmg"
  xcrun notarytool submit "$dmg" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --output-format json > "$RUNNER_TEMP/homebrew-dmg-notary.json"
  jq -e '.status == "Accepted"' "$RUNNER_TEMP/homebrew-dmg-notary.json"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
fi
mkdir -p "$RUNNER_TEMP/homebrew-mount"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$RUNNER_TEMP/homebrew-mount"
trap 'hdiutil detach "$RUNNER_TEMP/homebrew-mount" -force' EXIT
if [[ "$SIGNING_MODE" == signed ]]; then
  Scripts/verify-signing.sh --release "$RUNNER_TEMP/homebrew-mount/TinyPrune.app"
else
  Scripts/verify-signing.sh "$RUNNER_TEMP/homebrew-mount/TinyPrune.app"
fi
(cd "$RUNNER_TEMP" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
python3 Scripts/distribution.py metadata
