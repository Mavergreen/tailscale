#!/bin/sh
# platform: host-agnostic
# make_app.sh <systray-binary> <out .app> <version> [icon.icns]
# Wrap the tailscale-systray Go binary in a menu-bar-only (LSUIElement) .app. No ObjC -- the Go binary
# IS the app; the bundle just gives it an Info.plist so LaunchServices treats it as a menu-bar agent.
# An optional .icns is installed as the bundle icon (CFBundleIconFile) so Finder/About show the Tailscale
# logo instead of the generic app icon; omit it and the bundle simply has no custom icon.
set -eu
BIN=$1; APP=$2; VER=$3; ICON=${4:-}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 0755 "$BIN" "$APP/Contents/MacOS/tailscale-systray"
ICON_PLIST=""
if [ -n "$ICON" ]; then
  [ -f "$ICON" ] || { echo "make_app: icon not found: $ICON" >&2; exit 1; }
  install -m 0644 "$ICON" "$APP/Contents/Resources/Tailscale.icns"
  ICON_PLIST='  <key>CFBundleIconFile</key><string>Tailscale.icns</string>
'
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mavericks Tailscale</string>
  <key>CFBundleDisplayName</key><string>Mavericks Tailscale</string>
  <key>CFBundleIdentifier</key><string>dev.mavergreen.tailscale-systray</string>
  <key>CFBundleExecutable</key><string>tailscale-systray</string>
${ICON_PLIST}  <key>CFBundleVersion</key><string>${VER}</string>
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.9</string>
</dict>
</plist>
PLIST
echo "$APP"
