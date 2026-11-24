#!/bin/sh
# platform: host-agnostic
#   usage: fetch-clang22.sh     prints the prefix of the clang22 release components/clang22/version pins, for
#          this host, through shipyard's fetch_clang22.sh: the Linux archive on Linux, the cross pkg on a modern
#          Mac, the native pkg on 10.9. On Linux the archive's clang.cfg is then pointed at the pinned 10.9 SDK,
#          unless it already is.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/build/msc.sh"
d="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO/components/clang22")"
for b in clang ld64.lld llvm-lipo llvm-otool llvm-nm llvm-strings; do
  [ -x "$d/bin/$b" ] || { echo "fetch-clang22: $d lacks bin/$b" >&2; exit 1; }
done
if [ "$(uname -s)" = Linux ]; then
  sdk="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; l="$d/SDKs/MacOSX10.9.sdk"
  if [ -L "$l" ] && [ "$(cd "$l" && pwd -P)" = "$(cd "$sdk" && pwd -P)" ]; then :; else "$d/bin/setup-sdk" "$sdk" >&2; fi
fi
echo "$d"
