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
echo "PASS: hooks-test"
