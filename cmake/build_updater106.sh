#!/bin/sh
# build_updater106.sh — build the 10.6-native TailscaleUpdater.app.
# Pure ObjC, no external framework, no Go runtime — compiled directly
# with /usr/bin/clang against the prepared 10.6 SDK.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; VER="${2:-1.0}"
# Only probe PATH when the override is unset (command -v fails hard
# under set -e when go isn't found, making the override unreachable).
if [ -n "${MAVERICKS_GO_PREFIX:-}" ]; then
  PREFIX="$MAVERICKS_GO_PREFIX"
else
  GO_BIN="$(command -v go 2>/dev/null)" || {
    echo 'build_updater106: go not on PATH and MAVERICKS_GO_PREFIX not set' >&2; exit 1; }
  PREFIX="$(cd "$(dirname "$GO_BIN")/.." && pwd)"
fi

SDK=$(sh "$ROOT/cmake/legacy106/prepare_sdk106.sh" "$PREFIX" "$ROOT")
APP="$OUT/TailscaleUpdater106.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The feed URL is build-configurable so forks get the right repo.
# Default: derive from the git remote, fall back to the upstream repo.
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null \
  | sed 's|.*github.com[:/]||;s|\.git$||' || true)"
[ -n "$REPO" ] || REPO="startergo/tailscale-legacy"
FEED_URL="${UPDATER_FEED_URL:-https://github.com/${REPO}/releases/latest/download/appcast-10.6.xml}"

/usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.6 \
  -x objective-c -fno-objc-arc \
  -Wno-deprecated-declarations -Wno-format-security \
  -DUPDATER_FEED_URL="\"$FEED_URL\"" \
  -framework Cocoa \
  -o "$APP/Contents/MacOS/TailscaleUpdater106" \
  "$ROOT/updater/updater106.m"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>TailscaleUpdater106</string>
  <key>CFBundleIdentifier</key>        <string>dev.mavergreen.TailscaleUpdater106</string>
  <key>CFBundleVersion</key>           <string>$VER</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>TailscaleUpdater106</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>LSUIElement</key>               <true/>
  <key>LSMinimumSystemVersion</key>    <string>10.6</string>
</dict>
</plist>
PLIST

echo "OK: $APP"
