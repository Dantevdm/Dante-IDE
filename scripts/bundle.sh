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
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="build/Dante.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Dante" "$app/Contents/MacOS/Dante"

# SwiftPM resource bundles (from dependencies) live next to the binary.
find "$bin_dir" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$app/Contents/Resources/" \;

version="$(git describe --tags --always 2>/dev/null || echo 0.1)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dante</string>
  <key>CFBundleDisplayName</key><string>Dante</string>
  <key>CFBundleIdentifier</key><string>dev.dante.ide</string>
  <key>CFBundleExecutable</key><string>Dante</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS runs it locally.
codesign --force --sign - "$app" >/dev/null 2>&1 || true

echo "Built $app ($configuration)"
if $open_after; then open "$app"; fi
