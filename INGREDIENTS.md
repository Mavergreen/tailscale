# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient* is
an input to the product; the *own upstream* is the thing this repo exists to port. An own-upstream bump
cuts `<upstream>-mavericks.1`; an ingredient bump cuts a `-mavericks.(N+1)` repackage of the same
upstream, via `.github/workflows/repackage-on-ingredient-bump.yml`.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Tailscale source (own upstream) | `components/tailscale/version` (`REPO=` + `REF=`) | ✅ `github-tags`, **stable-only** (see below) | `release-on-bump.yml` asks `release.yml` to cut `<upstream>-mavericks.1`, forward-only |
| Mavergreen Go cross toolchain (go127-cross; its runtime and Recaulk's `librecaulk.a` are linked in) | `components/golang/version` | ✅ `github-releases` on `Mavergreen/golang-127`, `-mavericks.N` versioning (one Go line; moving lines is a hand edit of the pin + `depNameTemplate`) | watched path → repackage dispatched → `-mavericks.(N+1)` rebuilt on the new Go |
| Recaulk's headers (`include/recaulk`, for cgo; the toolchain's CC wrapper links its `librecaulk.a` but adds no include path) | derived, not pinned: `build_tailscale.sh` reads `recaulk_version` from the pinned golang release's `build-info-native.txt` and fetches that Recaulk release, refusing it unless its `librecaulk.a` is the toolchain's | moves with the golang pin | rides the golang repackage |
| clang22 (go127-cross's CC wrapper links every binary through it; it compiles and links the Sparkle updater, x86_64 at 10.9; its `llvm-*` tools read the Mach-O for the compat guard and conformance) | `components/clang22/version` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | watched path → repackage dispatched → `-mavericks.(N+1)` |
| MacOSX10.9 SDK (sdk109, which install@v1 provisions as go127-cross's require), packaging and signing scripts | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag: content changes without the pin changing, so nothing auto-repackages |
| Sparkle, in the updater | shipyard's `fetch_sparkle_framework.sh`, pinned by hash there | ❌ untrackable here: shipyard owns that pin | follows shipyard |

## Carried changes

- `patches/`: our changes to Tailscale's own source (the packaging type, the OS version report, the
  menu-bar app's behaviour, darwin exit nodes).
- `overlays/systray_darwin.m.patch`: product-specific behaviour, not a back-fill. fyne.io/systray's
  status item uses `NSStatusItem.button` (10.10) and the 10.12 names; built against the 10.9 SDK, the
  overlay drives the pre-Yosemite `NSStatusItem` API (image, title, menu) instead. It is not a
  Recaulk back-fill: `NSStatusItem.button` is a 10.10 AppKit view that 10.9's status item cannot
  supply with its real behaviour, so the overlay chooses a different design for 10.9 and changes what
  the menu-bar item does there. Retire it when fyne.io/systray itself has a pre-10.10 path, or when
  Tailscale's systray no longer vendors fyne.io/systray (`build_tailscale.sh` already skips the
  overlay then).
- certstore carries no overlay: its post-10.9 Security calls (`SecKeyCreateSignature` and the
  `SecKeyAlgorithm` constants, `SecTrustEvaluateWithError`, `SecTrustCopyCertificateChain`) are
  declared by Recaulk's headers and defined by the toolchain's `librecaulk.a`. `tests/certstore`
  checks them through certstore on 10.9. On 10.9, RSA-PSS fails with `errSecParam` (10.9's Security
  has no RSA-PSS primitive), so tailscaled's machine-certificate signing, which uses RSA-PSS, still
  cannot sign there.

Not ingredients: `cmake/`, `build/`, `packaging/`, `dist/` (the LaunchDaemon/Agent plists and
pre/postinstall scripts), and the updater's public key are this repo's own recipe. A change there is a
repackage you cut deliberately.

## Where it builds

Everything builds on Linux (`ubuntu-latest`): the three Go binaries with go127-cross, the updater with
clang22 through shipyard's `build_updater.sh`, and the standalone archive and the pkg through shipyard's
stevedore seams (`stage_standalone.sh`, `stage_pkg_from_archive.sh`, `stage_product.sh`,
`build_component_pkg.sh`, `set_install_floor.sh`). The only Mac in the release is the 10.9 guest
(`Mavergreen/mavericks-vm`, run from a Linux runner) that `on-target` installs and runs them on.

Tailscale ships x86_64 only, for 10.9, and so does its updater: there is no arm64 slice, so no
`modern-smoke` job and no macOS runner. The standalone archive, `tailscale-<version>-macos-x86_64.tar.gz`,
holds `tailscaled`, the CLI and the menu-bar app; the pkg is derived from it
(`packaging/tailscale.standalone-bundled` bundles nothing) and adds the updater, the launchd jobs and
the install scripts.

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
expected`, the macOS build job that `required (release)` has since replaced) and cut no release at all. Both paths publish inline, with the tag minted by
`action-gh-release` at the built commit.
