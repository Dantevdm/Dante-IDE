#!/usr/bin/env bash
# Builds a release of Dante as build/Dante-<version>.dmg.
#   scripts/release.sh 0.2.0
#
# Signing and notarisation use what this Mac has, and say what they skipped:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   signs with the hardened runtime
#   NOTARY_PROFILE=dante                                      notarises and staples the DMG
# (create the profile once with: xcrun notarytool store-credentials dante --apple-id … --team-id …)
# Without DEVELOPER_ID the app is ad-hoc signed: it runs on this Mac, and elsewhere only
# after right-click → Open (or `xattr -dr com.apple.quarantine /Applications/Dante.app`).
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if [[ -z "$version" ]]; then
  version="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)"
fi
if [[ -z "$version" ]]; then echo "usage: scripts/release.sh <version>" >&2; exit 1; fi

DANTE_VERSION="$version" scripts/bundle.sh
app="build/Dante.app"

# SwiftPM writes the build folder's path into the binary (it looks for resource bundles
# there first), so a build under your home folder carries your user name. Build published
# releases from a neutral checkout, e.g. `git worktree add /tmp/dante-release v0.2.0`.
if strings -a "$app/Contents/MacOS/Dante" | grep -q -F "$HOME/"; then
  echo "Note: the binary contains $HOME (the build folder's path). Build from a folder outside your home before publishing."
fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Signing with the Developer ID and the hardened runtime…"
  # --deep doesn't reach the `dante` command in Resources/bin, so sign it first.
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$app/Contents/Resources/bin/dante"
  codesign --force --deep --options runtime --timestamp --entitlements "$(dirname "$0")/Dante.entitlements" --sign "$DEVELOPER_ID" "$app"
  codesign --verify --strict --verbose=1 "$app"
else
  echo "No DEVELOPER_ID set: the app is ad-hoc signed and Gatekeeper will warn on other Macs."
fi

dmg="build/Dante-${version}.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Dante ${version}" -srcfolder "$staging" -ov -format UDZO "$dmg"
if [[ -n "${DEVELOPER_ID:-}" ]]; then codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"; fi

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Notarising (this takes a few minutes)…"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
else
  echo "Not notarised: set DEVELOPER_ID and NOTARY_PROFILE to notarise."
fi

(cd build && shasum -a 256 "Dante-${version}.dmg") | tee "$dmg.sha256"
echo "Built $dmg"
