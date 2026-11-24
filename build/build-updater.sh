#!/bin/sh
# platform: host-agnostic
#   usage: build-updater.sh VERSION OUT-DIR
#          Builds tailscale-updater.app, x86_64 at 10.9, with clang22 at components/clang22's pin, through
#          shipyard's build_updater.sh, and refuses one that links a Tailscale product. Prints
#          OUT-DIR/tailscale-updater.app.
# spec: mavergreen-conventions SKILL.md "Sparkle updater" -- the updater builds with clang22 on every
#       host through build_updater.sh, and must not link the product it updates
set -eu
[ $# -eq 2 ] || { echo "usage: build-updater.sh VERSION OUT-DIR" >&2; exit 2; }
VER=$1; OUT=$2
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/build/msc.sh"
CL="$(sh "$REPO/build/fetch-clang22.sh")"
app="$(sh "$SHIPYARD_SCRIPTS/build_updater.sh" --product tailscale --display-name "Mavericks Tailscale" \
  --confirm-title "Mavericks Tailscale updated" \
  --confirm-body "The Tailscale daemon, CLI, and menu-bar app were updated; the daemon reloaded." \
  --pubkey "$REPO/updater/ed25519_key.pub" --version "$VER" --clang22-pin "$REPO/components/clang22" \
  --arch x86_64 --icon "$REPO/Tailscale.icns" --log-prefix MavTailscaleUpdater \
  --relaunch-marker /tmp/.tailscale-updater-relaunched --out-dir "$OUT")"
exe="$app/Contents/MacOS/tailscale-updater"
[ -f "$exe" ] || { echo "build-updater: no $exe" >&2; exit 1; }
libs="$("$CL/bin/llvm-otool" -L "$exe")" || { echo "build-updater: llvm-otool -L $exe failed" >&2; exit 1; }
printf '%s\n' "$libs" >&2
if printf '%s\n' "$libs" | sed 1d | grep -iq tailscale; then
  echo "build-updater: $exe links a Tailscale product (self-update circularity)" >&2; exit 1
fi
echo "$app"
