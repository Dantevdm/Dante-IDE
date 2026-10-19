#!/usr/bin/env bash
# Builds Dante and wraps it in a macOS app bundle at build/Dante.app.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
#   scripts/bundle.sh --open     build, then launch
set -euo pipefail

cd "$(dirname "$0")/.."

configuration="release"
open_after=false
for arg in "$@"; do
  case "$arg" in
    debug) configuration="debug" ;;
    --open) open_after=true ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

swift build -c "$configuration" --product Dante
swift build -c "$configuration" --product dante-cli
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="build/Dante.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Dante" "$app/Contents/MacOS/Dante"

# The `dante` command; Settings → Tools says how to put it on the PATH.
mkdir -p "$app/Contents/Resources/bin"
cp "$bin_dir/dante-cli" "$app/Contents/Resources/bin/dante"

cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles (from dependencies) live next to the binary.
find "$bin_dir" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$app/Contents/Resources/" \;

version="$(git describe --tags --always 2>/dev/null || echo 0.1)"
# The marketing version: DANTE_VERSION (set by release.sh), else the latest v-tag, else 0.1.
short_version="${DANTE_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
short_version="${short_version:-0.1}"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dante</string>
  <key>CFBundleDisplayName</key><string>Dante</string>
  <key>CFBundleIdentifier</key><string>dev.dante.ide</string>
  <key>CFBundleExecutable</key><string>Dante</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${short_version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Dante listens while you hold the talk key, so you can speak to Claude.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Dante turns what you say to Claude into text, on this Mac.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.dante.ide.open</string>
      <key>CFBundleURLSchemes</key><array><string>dante</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Source</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.source-code</string><string>public.plain-text</string><string>public.json</string><string>public.yaml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign with a stable identity when there is one: macOS keys microphone, speech and Keychain
# permissions to the signature, and an ad-hoc one changes with every build, so each build
# would ask again. DANTE_SIGN_IDENTITY picks one; otherwise the first Apple Development
# certificate; otherwise ad-hoc, which still runs locally.
identity="${DANTE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')
fi
sign() { codesign --force --sign "${identity:--}" "$@" >/dev/null 2>&1 || codesign --force --sign - "$@" >/dev/null 2>&1 || true; }
[ -f "$app/Contents/Resources/bin/dante" ] && sign "$app/Contents/Resources/bin/dante"
sign "$app"

echo "Built $app ($configuration)"
if $open_after; then open "$app"; fi
