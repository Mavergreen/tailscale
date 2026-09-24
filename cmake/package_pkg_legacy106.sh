#!/bin/sh
# package_pkg_legacy106.sh — the Snow Leopard floor variant of package_pkg.sh.
# Differences from the 10.9 product:
#   - hard install floor 10.6 (vs 10.9.5)
#   - NO Sparkle updater (not yet validated on 10.6): the postinstall already
#     tolerates its absence (agent-load.sh optional), and the systray's
#     "Check for updates" item simply has no helper to hand off to.
# Payload layout is identical to the 10.9 product (native darwin paths:
# tailscaled in /usr/local/sbin, state under /Library/Tailscale).
#
# Usage: package_pkg_legacy106.sh --out PKG --version V --tailscaled BIN --tailscale BIN \
#          --systray-app APP.app --daemon-plist PLIST --systray-agent PLIST --dist DIR
#
# Wired into release.yml (the 10.6 packaging step) and usable standalone. To build a Snow Leopard pkg manually (CI does this automatically) after 'cmake --preset
# cross-legacy && cmake --build --preset cross-legacy' (binaries land out of tree,
# $MAVERICKS_BUILD_ROOT/<repo>-cross-legacy/gobin):
#   . build/msc.sh   # exports SHIPYARD_SCRIPTS
#   sh cmake/package_pkg_legacy106.sh \
#     --out tailscale-1.102.4-mavericks-legacy106.pkg --version 1.102.4 \
#     --tailscaled <...>-cross-legacy/gobin/tailscaled \
#     --tailscale <...>-cross-legacy/gobin/tailscale \
#     --systray-app <app-bundle> \
#     --daemon-plist dist/dev.mavergreen.tailscaled.plist \
#     --systray-agent dist/dev.mavergreen.tailscale-systray.plist --dist dist
set -eu
export COPYFILE_DISABLE=1
OUT=""; VER=""; TSD=""; TS=""; SYSTRAY=""; DAEMON=""; AGENT=""; DIST=""; UPD_APP=""
SHIPYARD="${SHIPYARD_SCRIPTS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;            --version) VER="$2"; shift 2;;
    --tailscaled) TSD="$2"; shift 2;;     --tailscale) TS="$2"; shift 2;;
    --systray-app) SYSTRAY="$2"; shift 2;; --updater-app) UPD_APP="$2"; shift 2;;
    --daemon-plist) DAEMON="$2"; shift 2;;
    --systray-agent) AGENT="$2"; shift 2;; --dist) DIST="$2"; shift 2;;
    *) echo "package_pkg_legacy106: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$OUT" ] && [ -n "$VER" ] && [ -n "$TSD" ] && [ -n "$TS" ] && [ -n "$SYSTRAY" ] \
  && [ -n "$DAEMON" ] && [ -n "$AGENT" ] && [ -n "$DIST" ] \
  || { echo "package_pkg_legacy106: need --out --version --tailscaled --tailscale --systray-app --daemon-plist --systray-agent --dist" >&2; exit 2; }
# Updater is optional (the no-updater path is supported for CI/debug builds)
UPD_APPDIR="/Library/Application Support/Mavergreen"
AGENT_LABEL="dev.mavergreen.tailscale-updatecheck"
if [ -n "${UPD_APP:-}" ]; then
  [ -d "$UPD_APP" ] || { echo "package_pkg_legacy106: --updater-app must be an .app bundle dir: $UPD_APP" >&2; exit 1; }
fi
[ -n "$SHIPYARD" ] || { echo "package_pkg_legacy106: SHIPYARD_SCRIPTS not set" >&2; exit 2; }

for h in set_install_floor.sh build_component_pkg.sh assert_pkg_installs_in_place.sh \
         postinstall-stop-gui.sh assert_gui_relaunch_safe.sh stage_updater.sh; do
  [ -f "$SHIPYARD/$h" ] || { echo "package_pkg_legacy106: shared helper missing: $SHIPYARD/$h" >&2; exit 1; }; done
for f in "$TSD" "$TS" "$DAEMON" "$AGENT" "$DIST/scripts/preinstall" "$DIST/scripts/postinstall"; do
  [ -f "$f" ] || { echo "package_pkg_legacy106: missing input (or not a regular file): $f" >&2; exit 1; }; done
[ -d "$SYSTRAY" ] || { echo "package_pkg_legacy106: --systray-app must be an .app bundle directory, got: $SYSTRAY" >&2; exit 1; }

IDENT="dev.mavergreen.tailscale"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tailscale-pkg106.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
stage="$WORK/stage"; scripts="$WORK/scripts"; comp="$WORK/component.pkg"

# --- product payload (identical layout to the 10.9 product) ---
mkdir -p "$stage/usr/local/sbin" "$stage/usr/local/bin" "$stage/Applications" \
         "$stage/Library/LaunchDaemons" "$stage/Library/LaunchAgents"
install -m 0755 "$TSD" "$stage/usr/local/sbin/tailscaled"
install -m 0755 "$TS"  "$stage/usr/local/bin/tailscale"
cp -R "$SYSTRAY" "$stage/Applications/Mavericks Tailscale.app"
install -m 0644 "$DAEMON" "$stage/Library/LaunchDaemons/dev.mavergreen.tailscaled.plist"
install -m 0644 "$AGENT"  "$stage/Library/LaunchAgents/dev.mavergreen.tailscale-systray.plist"

# Updater: our own 10.6-native updater (replaces the Sparkle-based one the
# 10.9 product ships -- Sparkle's binary declares min-10.9). Staged by the
# SAME shared helper the 10.9 product uses: it renders the daily update-check
# LaunchAgent from shipyard's template and emits agent-load.sh, which the
# shared postinstall (spliced below) sources when present.
if [ -n "${UPD_APP:-}" ]; then
  sh "$SHIPYARD/stage_updater.sh" --stage "$stage" --app "$UPD_APP" --app-dir "$UPD_APPDIR" \
    --agent-label "$AGENT_LABEL" --snippet-out "$scripts/agent-load.sh"
fi

# --- install scripts (no-updater build: agent-load.sh is simply absent) ---
# The staged preinstall additionally REMOVES a 10.9 product's updater leftovers
# (this build ships none): keeping them would leave a daily update-check agent
# relaunching an updater that upgrades the box back to a 10.9-floor build.
mkdir -p "$scripts"
# Compose preinstall: shebang + the original script (updater cleanup
# and agent loading belong in POSTINSTALL, after the payload is laid down).
{
  head -1 "$DIST/scripts/preinstall"
  tail -n +2 "$DIST/scripts/preinstall"
} > "$scripts/preinstall"
chmod 0755 "$scripts/preinstall"

# Compose postinstall: the original (it sources the staged agent-load.sh when
# present) + old-updater cleanup if this is a no-updater build replacing a
# 10.9 install.
{
  # Strip trailing 'exit 0' — appended blocks below must execute.
  sed '/^exit 0$/d' "$DIST/scripts/postinstall"
  if [ -z "${UPD_APP:-}" ]; then
    cat <<'POSTCLEAN'
# legacy106 (no-updater build): remove any 10.9-product updater leftovers
# so the old daily update agent cannot relaunch and downgrade this install.
CONSOLE_UID=$(stat -f %u /dev/console 2>/dev/null || echo 0)
if [ "${CONSOLE_UID:-0}" -gt 0 ]; then
  launchctl asuser "$CONSOLE_UID" launchctl unload \
    /Library/LaunchAgents/dev.mavergreen.tailscale-updatecheck.plist 2>/dev/null || true
fi
rm -f /Library/LaunchAgents/dev.mavergreen.tailscale-updatecheck.plist
rm -rf "/Library/Application Support/Mavergreen/TailscaleUpdater.app"
rm -rf "/Library/Application Support/Mavergreen/TailscaleUpdater106.app"
rm -rf "/Library/Application Support/ModernMavericks/TailscaleUpdater.app"
POSTCLEAN
  fi
} > "$scripts/postinstall"
chmod 0755 "$scripts/postinstall"
# NOTE: postinstall was already composed above (original + agent/cleanup)
install -m 0644 "$SHIPYARD/postinstall-stop-gui.sh" "$scripts/stop-gui.sh"

sh "$SHIPYARD/assert_gui_relaunch_safe.sh" "$scripts/postinstall" >&2
sh -n "$scripts/postinstall" || { echo "package_pkg_legacy106: postinstall syntax error" >&2; exit 1; }
sh -c '. "$1"; command -v mav_stop_gui_instance >/dev/null' _ "$scripts/stop-gui.sh" \
  || { echo "package_pkg_legacy106: staged stop-gui.sh broken" >&2; exit 1; }

# --- flat component pkg, install-in-place ---
find "$stage" -name '._*' -delete 2>/dev/null || true
sh "$SHIPYARD/build_component_pkg.sh" --root "$stage" --identifier "$IDENT" --version "$VER" \
  --install-location / --scripts "$scripts" --out "$comp" >&2

# --- product archive with the hard 10.6 OS floor ---
sh "$SHIPYARD/set_install_floor.sh" \
  --identifier "$IDENT" --title "Tailscale (Snow Leopard floor) $VER" \
  --component "$comp" --out "$OUT" --require-scripts --min-os 10.6 >&2

sh "$SHIPYARD/assert_pkg_installs_in_place.sh" "$OUT" >&2
echo "$OUT"
