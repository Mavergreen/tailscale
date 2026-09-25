#!/bin/sh
# platform: host-agnostic
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/tailscale-hooks.XXXXXX")"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$W/stub"
for c in launchctl stat; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\necho 501\n' "$c" "$W" > "$W/stub/$c"; chmod +x "$W/stub/$c"; done
: > "$W/calls"
V="$W/vol"; mkdir -p "$V"
ROOT="$V" PATH="$W/stub:$PATH" sh "$R/dist/hooks/preinstall.sh" || fail "the preinstall hook must succeed when installing to another volume"
ROOT="$V" PATH="$W/stub:$PATH" sh "$R/dist/hooks/postinstall.sh" || fail "the postinstall hook must succeed when installing to another volume"
[ ! -s "$W/calls" ] || fail "installing to another volume must not touch the running system: $(cat "$W/calls")"
[ -d "$V/usr/local/mavergreen/var/tailscale" ] || fail "the postinstall creates tailscaled's state directory on the target volume"
[ -d "$V/Library/Logs/Tailscale" ] || fail "the postinstall creates the log directory on the target volume"
grep -q '<string>/usr/local/mavergreen/tailscale/sbin/tailscaled</string>' "$R/dist/dev.mavergreen.tailscaled.plist" \
  || fail "launchd runs tailscaled from the tree, not the farm"
grep -q -- '--state=/usr/local/mavergreen/var/tailscale/tailscaled.state' "$R/dist/dev.mavergreen.tailscaled.plist" \
  || fail "tailscaled keeps its state in var/tailscale (D3)"

# --- ephemeral-node trap: on the BOOT volume (ROOT empty), the postinstall must create the state
#     directory (mode 0700) BEFORE it (re)loads tailscaled's LaunchDaemon, or a fresh/upgraded
#     install briefly runs with no state dir and comes up as an ephemeral node. Every tool the
#     postinstall can reach on the boot volume is stubbed (mkdir, launchctl, stat, pkill, sleep) so
#     this never touches the real system, even though ROOT is empty this time.
W2="$W/boot"; mkdir -p "$W2/stub" "$W2/scripts"
for c in mkdir launchctl pkill sleep; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$W2" > "$W2/stub/$c"; chmod +x "$W2/stub/$c"; done
printf '#!/bin/sh\necho "stat $*" >> "%s/calls"\necho 501\n' "$W2" > "$W2/stub/stat"; chmod +x "$W2/stub/stat"
: > "$W2/calls"
cp "$R/dist/hooks/postinstall.sh" "$W2/scripts/postinstall"
cat > "$W2/scripts/stop-gui.sh" <<'STOPGUI'
mav_stop_gui_instance() {
  pkill -TERM -U "$2" -f "$1" 2>/dev/null || true
  sleep 1
  pkill -KILL -U "$2" -f "$1" 2>/dev/null || true
}
STOPGUI
ROOT="" PATH="$W2/stub:$PATH" sh "$W2/scripts/postinstall" \
  || fail "the postinstall hook must succeed on the boot volume too"
mkdir_line="$(grep -n -- '-m 0700 .*var/tailscale' "$W2/calls" | head -1 | cut -d: -f1)"
load_line="$(grep -n -- 'load -w .*tailscaled\.plist' "$W2/calls" | head -1 | cut -d: -f1)"
[ -n "$mkdir_line" ] || fail "the postinstall never creates the state dir with mode 0700 (ephemeral-node trap)"
[ -n "$load_line" ] || fail "the postinstall never (re)loads tailscaled's LaunchDaemon"
[ "$mkdir_line" -lt "$load_line" ] \
  || fail "the state directory (mode 0700) must be created BEFORE tailscaled's LaunchDaemon is (re)loaded, or a fresh install runs as an ephemeral node"

echo "PASS: hooks-test"
