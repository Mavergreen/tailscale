#!/bin/sh
# Build tailscaled / tailscale / tailscale-systray for darwin/amd64 min-10.9 with the Mavergreen
# go126 toolchain (its go.env default CC wrapper supplies the 10.9 SDK + target flags + legacy shim +
# -Wl,-U weak-symbol allowances -- so nothing target-specific is passed here). Applies our vendored
# subset: patches/ = source-tree tweaks, overlays/ = third-party-module 10.9-SDK shims.
#   $1 SRC   pinned clone (read-only reference)
#   $2 OUT   output dir (binaries land here; a wrksrc/ copy is built alongside)
#   $3 GO    go binary (the MM go126 .pkg)
#   $4 ROOT  repo root (for patches/ + overlays/)
#   $5 VER   product version (longStamp)
set -eu
SRC=$1; OUT=$2; GO=$3; ROOT=$4; VER=$5
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
# Go than our go126 FAILS LOUDLY here -- which (via ci.yml) correctly blocks the Renovate bump until
# mavericks-golang catches up, instead of shipping a non-10.9 build.
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

# 2. Vendor the module graph, then overlay the third-party 10.9-SDK shims into vendor/ (these modules
#    call Security/Cocoa APIs newer than the 10.9 SDK and won't compile without a version-gated reimpl).
unset CC
echo ">> go mod vendor"; "$GO" mod vendor
echo ">> overlay certstore shim"
patch -p4 -d vendor/github.com/tailscale/certstore < "$ROOT/overlays/certstore_darwin.go.patch"
if [ -d vendor/fyne.io/systray ]; then
  echo ">> overlay systray shim"; cp "$ROOT/overlays/systray_darwin.m" vendor/fyne.io/systray/systray_darwin.m
fi

# 3. Build each binary. -linkmode=external routes even pure-Go binaries through go.env's min-10.9 CC
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
echo "OK: tailscaled / tailscale / tailscale-systray -> $OUT"
