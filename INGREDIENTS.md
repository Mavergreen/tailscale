# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient* is
an input to the product; the *own upstream* is the thing this repo exists to port. An own-upstream bump
cuts `<upstream>-mavericks.1`; an ingredient bump cuts a `-mavericks.(N+1)` repackage of the same
upstream, via `.github/workflows/repackage-on-ingredient-bump.yml`.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Tailscale source (own upstream) | `components/tailscale/version` (`REPO=` + `REF=`) | ✅ `github-tags`, **stable-only** (see below) | `release-on-bump.yml` asks `release.yml` to cut `<upstream>-mavericks.1`, forward-only |
| Mavergreen Go cross toolchain | `components/golang/version` | ✅ `github-releases` on `Mavergreen/golang` | watched path → repackage dispatched → `-mavericks.(N+1)` rebuilt on the new Go |
| MacOSX10.9 SDK, Sparkle framework | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag: content changes without the pin changing, so nothing auto-repackages |

Not ingredients: `cmake/`, `dist/` (the LaunchDaemon/Agent plists and pre/postinstall scripts), and the
updater are this repo's own recipe. A change there is a repackage you cut deliberately.

## Why the tailscale pin is stable-only

Tailscale ships unstable releases as odd minor versions (1.99.x) and stable as even (1.98.x, 1.102.x).
The `allowedVersions` rule on `tailscale-source` (`/^v?\d+\.\d*[02468]\.\d+$/`) keeps Renovate on the
stable track; without it an unstable tag would auto-open a bump PR for a release we would never ship.

## Why both auto-cutters exist, and why neither commits to main

- A **source pin bump** is a new upstream → `-mavericks.1`. `release-on-bump.yml` dispatches
  `release.yml` with `upstream_release=true`, which derives the version from the pinned source's
  `VERSION.txt`, checks it is strictly ahead of the newest shipped tag, and publishes inline.
- A **golang pin bump** is an ingredient → `-mavericks.(N+1)`, dispatched by the shared
  `repackage-on-ingredient-bump.yml`, which excludes `components/tailscale/version` as own-upstream.

Neither commits a version bump to `main`, and that is not an aesthetic choice: **branch protection here
requires a status check that a fresh bot commit cannot have**, so the old commit-then-push-a-tag shape
was rejected outright (`GH006: Required status check "Cross-build + compat gate (macos-26)" is
expected`) and cut no release at all. Both paths publish inline, with the tag minted by
`action-gh-release` at the built commit.

## Upgrading a pre-flag-day install

tailscaled's state moved to `/usr/local/mavergreen/var/tailscale/tailscaled.state`; there is no
migration code carrying the old `/Library/Tailscale/tailscaled.state` over (no users pre-date this
layout, so none is warranted). On the maintainer's own box, move the file by hand before the daemon
first starts under the new layout (`mode 0600`), or the node re-registers as a new device.
