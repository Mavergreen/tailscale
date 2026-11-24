#!/bin/sh
# platform: host-agnostic -- stevedore expands the product archive and cpio lists its payload
#   usage: package-test.sh PKG GOBIN
#          The pkg must be named tailscale-<version>.pkg; its dev.mavergreen.tailscale component must
#          carry tailscaled, the tailscale CLI and the menu-bar app's tailscale-systray, each
#          byte-identical to the one in GOBIN that the compat guard passed, plus the manifest, the
#          LaunchDaemon and LaunchAgents, and the updater; every file in it world-readable and every
#          directory world-searchable. Exits 77 without its arguments.
set -eu
PKG="${1:-}"; GOBIN="${2:-}"
[ -n "$PKG" ] && [ -n "$GOBIN" ] || { echo "skip: usage: package-test.sh PKG GOBIN" >&2; exit 77; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/build/msc.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

case "$(basename "$PKG")" in tailscale-[0-9]*.pkg) ;; *) fail "the pkg is named tailscale-<version>.pkg, not $(basename "$PKG")" ;; esac
[ -f "$PKG" ] || fail "no pkg at $PKG"
T="$(mktemp -d "${TMPDIR:-/tmp}/tailscale-package-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
SD="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")"
"$SD" expand "$PKG" "$T/x" >/dev/null || fail "stevedore cannot expand $PKG"
C="$(grep -l 'identifier="dev.mavergreen.tailscale"' "$T"/x/*/PackageInfo | sed 1q)"
[ -n "$C" ] || fail "the product archive carries no dev.mavergreen.tailscale component"
C="$(dirname "$C")"
mkdir "$T/out"
gzip -dc < "$C/Payload" > "$T/payload.cpio" || fail "the pkg's payload does not decompress"
( cd "$T/out" && cpio -id --quiet < "$T/payload.cpio" ) || fail "cpio cannot extract the pkg's payload"

O="$T/out"
for p in usr/local/mavergreen/tailscale/mavergreen.plist \
         Library/LaunchDaemons/dev.mavergreen.tailscaled.plist \
         Library/LaunchAgents/dev.mavergreen.tailscale-systray.plist \
         Library/LaunchAgents/dev.mavergreen.tailscale-updatecheck.plist \
         "Applications/Mavericks Tailscale.app/Contents/Info.plist" \
         "Library/Application Support/Mavergreen/tailscale-updater.app/Contents/MacOS/tailscale-updater"; do
  [ -f "$O/$p" ] || fail "the payload carries no $p"
done
for pair in tailscaled:usr/local/mavergreen/tailscale/sbin/tailscaled \
            tailscale:usr/local/mavergreen/tailscale/bin/tailscale \
            "tailscale-systray:Applications/Mavericks Tailscale.app/Contents/MacOS/tailscale-systray"; do
  b="${pair%%:*}"; p="${pair#*:}"
  [ -f "$O/$p" ] || fail "the payload carries no $p"
  [ -x "$O/$p" ] || fail "$p is not executable"
  cmp -s "$O/$p" "$GOBIN/$b" || fail "$p is not byte-identical to the tested $GOBIN/$b"
done
bad="$(cd "$O" && { find . -type f ! -perm -004; find . -type d ! -perm -001; })"
[ -z "$bad" ] || fail "not world-readable or world-searchable: $bad"
echo "PASS: package-test"
