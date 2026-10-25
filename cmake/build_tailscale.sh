#!/bin/sh
# platform: macOS-only -- links CGO Mach-O binaries through the Mavergreen Go toolchain's Apple-clang/10.9-SDK CC wrapper
# Build tailscaled / tailscale / tailscale-systray for darwin/amd64 min-10.9 with the Mavergreen
# Go toolchain (its go.env default CC wrapper supplies the 10.9 SDK + target flags + Recaulk's
# librecaulk.a + -Wl,-U weak-symbol allowances, but no include path; step 3 adds Recaulk's headers).
# Applies our vendored subset: patches/ = source-tree tweaks, overlays/ = third-party-module changes.
#   $1 SRC      pinned clone (read-only reference)
#   $2 OUT      output dir (binaries land here; a wrksrc/ copy is built alongside)
#   $3 GO       go binary (the Mavergreen golang .pkg)
#   $4 ROOT     repo root (for patches/, overlays/, components/golang/version and tests/certstore/)
#   $5 VER      product version (longStamp)
#   $6 SCRIPTS  shipyard's scripts directory (fetch-release-pkg.sh, fetch_product_pkg.sh)
set -eu
SRC=$1; OUT=$2; GO=$3; ROOT=$4; VER=$5; SCRIPTS=$6
# Build on LOCAL disk. The repo (and thus a repo-relative OUT/SRC) is on NFS: slow, and it leaks
# ._ AppleDouble sidecars into vendor/ (which then break the build / contaminate archives). wrksrc +
# the Go build/module caches live under WORK ($HOME/.cache, local); override with MAVERICKS_TAILSCALE_WORK.
WORK="${MAVERICKS_TAILSCALE_WORK:-$HOME/.cache/mavericks-tailscale/work}"
WRK="$WORK/wrksrc"
export GOCACHE="$WORK/gocache" GOMODCACHE="$WORK/gomodcache" GOPATH="$WORK/gopath"
export COPYFILE_DISABLE=1   # no ._ sidecars when copying off the NFS source
# Pin the toolchain: NEVER let Go auto-download a newer stock toolchain to satisfy a go.mod `go`/
# `toolchain` directive. Stock Go isn't 10.9-safe (its own binary references post-10.9 symbols, and it
# lacks our CC wrapper), so an auto-download would silently escape the Mavergreen toolchain and
# yield binaries of unknown 10.9-safety. With GOTOOLCHAIN=local, a tailscale version that needs a newer
# Go than our pinned line FAILS LOUDLY here -- which (via ci.yml) correctly blocks the Renovate bump until
# the pin moves to a Mavergreen golang line that has it, instead of shipping a non-10.9 build.
export GOTOOLCHAIN=local
mkdir -p "$WORK" "$OUT"
rm -rf "$WRK"; mkdir -p "$WRK"
cp -R "$SRC/." "$WRK/"
rm -rf "$WRK/.git"
find "$WRK" -name '._*' -delete 2>/dev/null || true
cd "$WRK"

# 1. Source patches (pkgsrc -p0 format): accurate old-macOS version report + the Mavergreen
#    package stamp. (The pkgsrc go.mod + paths patches are pkgsrc-only and deliberately NOT here.)
for p in "$ROOT"/patches/*.patch; do echo ">> patch $(basename "$p")"; patch -p0 < "$p"; done

# 2. Vendor the module graph, then overlay systray's pre-Yosemite status item into vendor/.
unset CC
echo ">> go mod vendor"; "$GO" mod vendor
if [ -d vendor/fyne.io/systray ]; then
  echo ">> overlay systray status item"
  patch -p0 -d vendor/fyne.io/systray < "$ROOT/overlays/systray_darwin.m.patch"
fi
mkdir -p mavergreen
cp -R "$ROOT/tests/certstore" mavergreen/certstoretest

# 3. Recaulk's headers, from the Recaulk release the Go toolchain's librecaulk.a came from.
GOPIN="$(tr -d '[:space:]' < "$ROOT/components/golang/version")"
GOLINE="$(printf '%s' "${GOPIN%%-mavericks.*}" | cut -d. -f1,2 | tr -d .)"
INFO="$(sh "$SCRIPTS/fetch-release-pkg.sh" "golang-$GOLINE" "$GOPIN" build-info-native.txt "$WORK/golang-build-info/$GOPIN")"
RECAULK_VERSION="$(sed -n 's/^recaulk_version=//p' "$INFO")"
[ -n "$RECAULK_VERSION" ] || { echo "FATAL: golang $GOPIN's build-info names no recaulk_version" >&2; exit 1; }
RECAULK="$(sh "$SCRIPTS/fetch_product_pkg.sh" recaulk "$RECAULK_VERSION" "$WORK/recaulk")"
cmp -s "$RECAULK/lib/librecaulk.a" "$("$GO" env GOROOT)/lib/librecaulk.a" \
  || { echo "FATAL: $GO does not link Recaulk $RECAULK_VERSION's librecaulk.a, so its headers would not match" >&2; exit 1; }
export CGO_CFLAGS="-O2 -g -isystem $RECAULK/include/recaulk"

# 4. Build each binary. -linkmode=external routes even pure-Go binaries through go.env's min-10.9 CC
#    wrapper (Go 1.26 internal-links them to a 12.0 floor otherwise -- see mavericks-golang).
export CGO_ENABLED=1 GOARCH=amd64 GOFLAGS=-mod=vendor
# Stamp BOTH version strings to the clean upstream semver (e.g. 1.98.8). Without a stamp, tailscale
# derives the version from module VCS info -- stripped in our build -- and prints "<ver>-ERR-BuildInfo".
# We deliberately report the plain upstream version to the control server (Hostinfo.IPNVersion is
# version.Long()) rather than our full 1.98.8-mavericks.1: like other downstream packages, the
# package-specific suffix doesn't belong in the version the tailnet sees. Package identity is carried
# separately by hostinfo.SetPackage("Mavergreen").
SHORT=${VER%%-mavericks.*}
LD="-linkmode=external -X tailscale.com/version.longStamp=$SHORT -X tailscale.com/version.shortStamp=$SHORT"
for spec in tailscaled:./cmd/tailscaled tailscale:./cmd/tailscale tailscale-systray:./cmd/systray; do
  name=${spec%%:*}; pkg=${spec#*:}
  echo ">> build $name"
  "$GO" build -ldflags "$LD" -o "$OUT/$name" "$pkg"
  [ -f "$OUT/$name" ] || { echo "FATAL: no $name produced" >&2; exit 1; }
done
# 5. The exit-node code's tests and certstore's signing/trust tests, as 10.9 binaries: run by ctest on
#    a native build and by tests/on-mavericks.sh on a 10.9 guest. Never packaged: release.yml stages
#    the three above by name.
echo ">> build osrouter.test"
"$GO" test -c -ldflags=-linkmode=external -o "$OUT/osrouter.test" ./wgengine/router/osrouter
[ -f "$OUT/osrouter.test" ] || { echo "FATAL: no osrouter.test produced" >&2; exit 1; }
echo ">> build certstore.test"
"$GO" test -c -ldflags=-linkmode=external -o "$OUT/certstore.test" ./mavergreen/certstoretest
[ -f "$OUT/certstore.test" ] || { echo "FATAL: no certstore.test produced" >&2; exit 1; }
echo "OK: tailscaled / tailscale / tailscale-systray / osrouter.test / certstore.test -> $OUT"
