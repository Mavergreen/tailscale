#!/bin/sh
# platform: host-agnostic
# Print the URL of upstream Tailscale's release notes for one version. shipyard's upstream-notes.sh
# calls this when a release ships a NEW upstream, and links the result from the release notes.
#   usage: upstream-release-notes-url.sh <upstream-version>      (bare: 1.102.3)
#
# Tailscale's GitHub releases only say "see https://tailscale.com/changelog", and that page is
# anchored by DATE (#2026-08-19-client), not by version -- so find the client entry whose title is
# exactly "Tailscale v<version>" and link its anchor. Each entry is
#   <div id="YYYY-MM-DD-client" class="changelog-entry ..."><header ...><h3 class="changelog-title ...">Tailscale v1.102.3</h3>
# Two client releases on one day share one anchor (1.92.1 and 1.92.2 are both #2025-12-10-client);
# the link then lands on that day, which is as close as the page allows.
#
# Some releases have no entry at all (1.102.0), and the page may be unreachable. Either way print
# the client changelog itself and say why on stderr: a less specific link beats none, and notes must
# never fail a release. Runs only when notes are generated, but stays 10.9-safe (BWK awk, no -E).
# TAILSCALE_CHANGELOG_SOURCE overrides where the page is read from (tests use a file:// fixture);
# the printed URL is always the public one.
set -eu
ver="${1:?usage: upstream-release-notes-url.sh <upstream-version>}"
page="https://tailscale.com/changelog"
src="${TAILSCALE_CHANGELOG_SOURCE:-$page}"

anchor="$( { curl -fsSL --retry 3 --max-time 60 "$src" 2>/dev/null || true; } \
  | tr '<' '\n' \
  | awk -v want="Tailscale v$ver" '
      /^div id="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-client"/ {
        split($0, f, "\""); id = f[2]; next
      }
      id != "" && /^h3 class="changelog-title/ {
        t = $0; sub(/^[^>]*>/, "", t); sub(/[ \t\r]+$/, "", t)
        if (t == want) { print id; exit }
        id = ""
      }')"

if [ -n "$anchor" ]; then
  printf '%s#%s\n' "$page" "$anchor"
else
  echo "upstream-release-notes-url: no changelog entry for Tailscale v$ver at $src; linking the client changelog" >&2
  printf '%s#client\n' "$page"
fi
