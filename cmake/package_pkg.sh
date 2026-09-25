#!/bin/sh
# platform: macOS-only -- drives stage_product.sh and build_component_pkg.sh, which need pkgbuild/productbuild/PlistBuddy
# Assemble the (unsigned) Tailscale product .pkg: tailscaled + tailscale CLI + the menu-bar Mavericks Tailscale.app,
# the Sparkle updater (.app + daily update-check LaunchAgent), the daemon LaunchDaemon + systray
# LaunchAgent, with a hard 10.9.5 install floor. Signing + appcast are separate (shared
# sign_and_appcast.sh) in the release workflow; this only builds the .pkg. Prints the .pkg path.
#
# Usage:
#   package_pkg.sh --out PKG --version V --tailscaled BIN --tailscale BIN --systray-app APP.app \
#     --updater-app APP.app --daemon-plist PLIST --systray-agent PLIST --dist DIR [--msc-scripts DIR]
set -eu
export COPYFILE_DISABLE=1
OUT=""; VER=""; TSD=""; TS=""; SYSTRAY=""; UPD_APP=""; DAEMON=""; AGENT=""; DIST=""; SHIPYARD="${SHIPYARD_SCRIPTS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;            --version) VER="$2"; shift 2;;
    --tailscaled) TSD="$2"; shift 2;;     --tailscale) TS="$2"; shift 2;;
    --systray-app) SYSTRAY="$2"; shift 2;; --updater-app) UPD_APP="$2"; shift 2;;
    --daemon-plist) DAEMON="$2"; shift 2;; --systray-agent) AGENT="$2"; shift 2;;
    --dist) DIST="$2"; shift 2;;          --msc-scripts) SHIPYARD="$2"; shift 2;;
    *) echo "package_pkg: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$OUT" ] && [ -n "$VER" ] && [ -n "$TSD" ] && [ -n "$TS" ] && [ -n "$SYSTRAY" ] \
  && [ -n "$UPD_APP" ] && [ -n "$DAEMON" ] && [ -n "$AGENT" ] && [ -n "$DIST" ] \
  || { echo "package_pkg: need --out --version --tailscaled --tailscale --systray-app --updater-app --daemon-plist --systray-agent --dist" >&2; exit 2; }
[ -n "$SHIPYARD" ] || { echo "package_pkg: SHIPYARD_SCRIPTS unset (install mavericks-shipyard, or pass --msc-scripts)" >&2; exit 2; }
for f in "$TSD" "$TS" "$DAEMON" "$AGENT" "$DIST/hooks/preinstall.sh" "$DIST/hooks/postinstall.sh"; do
  [ -f "$f" ] || { echo "package_pkg: missing input: $f" >&2; exit 1; }; done
for d in "$SYSTRAY" "$UPD_APP"; do [ -d "$d" ] || { echo "package_pkg: missing .app: $d" >&2; exit 1; }; done
for h in stage_product.sh set_install_floor.sh build_component_pkg.sh assert_pkg_installs_in_place.sh \
         postinstall-stop-gui.sh assert_gui_relaunch_safe.sh; do
  [ -f "$SHIPYARD/$h" ] || { echo "package_pkg: shared helper missing: $SHIPYARD/$h" >&2; exit 1; }; done

IDENT="dev.mavergreen.tailscale"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tailscale-pkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
stage="$WORK/stage"; scripts="$WORK/scripts"; comp="$WORK/component.pkg"

# --- product payload (Task 0: Tailscale's native darwin default paths, no path patch) ---
T="$stage/usr/local/mavergreen/tailscale"
mkdir -p "$T/sbin" "$T/bin" "$stage/Applications" "$stage/Library/LaunchDaemons" "$stage/Library/LaunchAgents"
install -m 0755 "$TSD" "$T/sbin/tailscaled"
install -m 0755 "$TS"  "$T/bin/tailscale"
cp -R "$SYSTRAY" "$stage/Applications/Mavericks Tailscale.app"
install -m 0644 "$DAEMON" "$stage/Library/LaunchDaemons/dev.mavergreen.tailscaled.plist"
install -m 0644 "$AGENT"  "$stage/Library/LaunchAgents/dev.mavergreen.tailscale-systray.plist"

# --- hooks + manifest, via the shared stager (derives the updater's identity from the registry) ---
mkdir -p "$scripts"
install -m 0644 "$SHIPYARD/postinstall-stop-gui.sh" "$scripts/stop-gui.sh"
find "$stage" -name '._*' -delete 2>/dev/null || true
sh "$SHIPYARD/stage_product.sh" --stage "$stage" --product tailscale --name "Tailscale for Mavericks" \
  --version "$VER" --updater-app "$UPD_APP" \
  --preinstall-hook "$DIST/hooks/preinstall.sh" --postinstall-hook "$DIST/hooks/postinstall.sh" \
  --scripts-out "$scripts" >&2

# Gate the assembled postinstall before it ships: if it relaunches the menu-bar app it must stop the
# old instance first (else two icons after an update). Then confirm the staged helper actually parses
# and defines the function the postinstall sources -- a missing/broken snippet would silently regress.
sh "$SHIPYARD/assert_gui_relaunch_safe.sh" "$scripts/postinstall" >&2
sh -n "$scripts/postinstall" || { echo "package_pkg: assembled postinstall has a syntax error" >&2; exit 1; }
sh -c '. "$1"; command -v mav_stop_gui_instance >/dev/null' _ "$scripts/stop-gui.sh" \
  || { echo "package_pkg: staged stop-gui.sh does not define mav_stop_gui_instance" >&2; exit 1; }

# --- flat component pkg (absolute layout -> install-location /). ---
# The shared helper forces install-in-place: BundleIsRelocatable=false so the menu-bar app + updater
# land at their DECLARED paths (never relocated onto a same-identifier bundle already on disk), and
# BundleIsVersionChecked=false so an update never skips a component whose on-disk version looks newer.
sh "$SHIPYARD/build_component_pkg.sh" --root "$stage" --identifier "$IDENT" --version "$VER" \
  --install-location / --scripts "$scripts" --out "$comp" >&2

# --- product archive with the hard 10.9.5 OS floor (shared helper) ---
sh "$SHIPYARD/set_install_floor.sh" \
  --identifier "$IDENT" --title "Tailscale for Mavericks $VER" \
  --component "$comp" --out "$OUT" --require-scripts --host-arch x86_64 >&2

# Gate the shipped product archive: every bundle must install in place (no relocation, no version-skip).
sh "$SHIPYARD/assert_pkg_installs_in_place.sh" "$OUT" >&2

echo "$OUT"
