#!/bin/sh
# platform: host-agnostic
# build/upstream-release-notes-url.sh: find a version's entry in tailscale's changelog, which is
# anchored by DATE, not version. Runs against a fixture shaped like the real page -- no network.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../build/upstream-release-notes-url.sh"
err="$(mktemp -t upstream-notes-url-err.XXXXXX)"; trap 'rm -f "$err"' EXIT
export TAILSCALE_CHANGELOG_SOURCE="file://$here/fixtures/changelog.html"

expect() {  # version expected-url [stderr-must-mention]
  got="$(sh "$S" "$1" 2>"$err")" || { echo "FAIL $1: exited non-zero"; cat "$err"; exit 1; }
  [ "$got" = "$2" ] || { echo "FAIL $1: expected $2, got '$got'"; cat "$err"; exit 1; }
  if [ -n "${3:-}" ]; then
    grep -q "$3" "$err" || { echo "FAIL $1: stderr should mention '$3'"; cat "$err"; exit 1; }
  elif [ -s "$err" ]; then
    echo "FAIL $1: unexpected warning"; cat "$err"; exit 1
  fi
}

# the entry's own date anchor -- not the newer 1.102.30 above it, not the service entry naming 1.102.3
expect 1.102.3 'https://tailscale.com/changelog#2026-08-19-client'
expect 1.102.2 'https://tailscale.com/changelog#2026-08-04-client'
# two client releases on one day share an anchor; it still lands on that day
expect 1.92.1  'https://tailscale.com/changelog#2025-12-10-client'
# a release with no changelog entry (1.102.0 had none) still gets a working link, and says why
expect 1.102.0 'https://tailscale.com/changelog#client' 'no changelog entry'
# so does an unreachable changelog: notes are prose and must never fail a release
TAILSCALE_CHANGELOG_SOURCE="file://$here/fixtures/does-not-exist.html" \
  expect 1.102.3 'https://tailscale.com/changelog#client' 'no changelog entry'

echo "PASS: upstream-release-notes-url"
