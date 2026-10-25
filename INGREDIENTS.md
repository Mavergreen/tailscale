# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient* is
an input to the product; the *own upstream* is the thing this repo exists to port. An own-upstream bump
cuts `<upstream>-mavericks.1`; an ingredient bump cuts a `-mavericks.(N+1)` repackage of the same
upstream, via `.github/workflows/repackage-on-ingredient-bump.yml`.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Tailscale source (own upstream) | `components/tailscale/version` (`REPO=` + `REF=`) | ✅ `github-tags`, **stable-only** (see below) | `release-on-bump.yml` asks `release.yml` to cut `<upstream>-mavericks.1`, forward-only |
| Mavergreen Go cross toolchain | `components/golang/version` | ✅ `github-releases` on `Mavergreen/golang-127` (one Go line; moving lines is a hand edit of the pin + `packageNameTemplate`) | watched path → repackage dispatched → `-mavericks.(N+1)` rebuilt on the new Go |
| Recaulk's headers (`include/recaulk`, for cgo; the toolchain's CC wrapper links its `librecaulk.a` but adds no include path) | derived, not pinned: `build_tailscale.sh` reads `recaulk_version` from the pinned golang release's `build-info-native.txt` and fetches that Recaulk release, refusing it unless its `librecaulk.a` is the toolchain's | moves with the golang pin | rides the golang repackage |
| Longboat (CI only: `ci.yml` and `release.yml` install it and run `longboat sdk install 10.9` before the Go cross pkg, which requires it; nothing of it ships) | `components/longboat/version` | ✅ `github-releases` on `Mavergreen/longboat`, `YYYYMMDD.N` versioning | no release: excluded from `repackage-on-ingredient-bump.yml`'s paths |
| MacOSX10.9 SDK, Sparkle framework | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag: content changes without the pin changing, so nothing auto-repackages |

## Carried changes

- `patches/`: our changes to Tailscale's own source (the packaging type, the OS version report, the
  menu-bar app's behaviour, darwin exit nodes).
- `overlays/systray_darwin.m.patch`: product-specific behaviour, not a back-fill. fyne.io/systray's
  status item uses `NSStatusItem.button` (10.10) and the 10.12 names; built against the 10.9 SDK, the
  overlay drives the pre-Yosemite `NSStatusItem` API (image, title, menu) instead. It changes what the
  menu-bar item does on 10.9, so it has no shared home.
- certstore carries no overlay: its post-10.9 Security calls (`SecKeyCreateSignature` and the
  `SecKeyAlgorithm` constants, `SecTrustEvaluateWithError`, `SecTrustCopyCertificateChain`) are
  declared by Recaulk's headers and defined by the toolchain's `librecaulk.a`. `tests/certstore`
  checks them through certstore on 10.9. On 10.9, RSA-PSS fails with `errSecParam` (10.9's Security
  has no RSA-PSS primitive), so tailscaled's machine-certificate signing, which uses RSA-PSS, still
  cannot sign there.

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

## Conformance deviations

- on-target: its 10.9 job (on-mavericks) runs in ci.yml, which publish cannot need; exit: move that job into release.yml and have publish need it
