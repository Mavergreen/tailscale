#!/bin/sh
# platform: host-agnostic
# Write UPSTREAM_VERSION = the pinned tailscale source's OWN VERSION.txt at the pinned REF.
#
# The pin (components/tailscale/version, Renovate-managed) is the single source of truth: bump the
# pin and the upstream version follows automatically, so there is no second file to remember to edit
# and no way for the two to disagree. Same shape as ed25519's derive-upstream-version.sh, which takes
# the pinned commit's date. UPSTREAM_VERSION is therefore build-derived and gitignored, never
# hand-edited; VERSION (the full <upstream>-mavericks.N) derives from it plus the shipped tags.
#
# Reads the file over HTTPS rather than cloning: this runs before anything is fetched, and one raw
# file is cheaper than a clone of tailscale.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
PIN="$ROOT/components/tailscale/version"

REPO=$(sed -n 's/^REPO=//p' "$PIN")
REF=$(sed -n 's/^REF=//p' "$PIN")
[ -n "$REPO" ] && [ -n "$REF" ] || { echo "derive-upstream-version: malformed $PIN" >&2; exit 1; }

slug=$(printf '%s' "$REPO" | sed -E 's#^https?://github.com/##; s#\.git$##')
UP=$(curl -fsSL "https://raw.githubusercontent.com/$slug/$REF/VERSION.txt" | tr -d '[:space:]')
case "$UP" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) echo "derive-upstream-version: no sane upstream version at $slug@$REF (got '$UP')" >&2; exit 1 ;;
esac

printf '%s\n' "$UP" > "$ROOT/UPSTREAM_VERSION"
printf '%s\n' "$UP"
