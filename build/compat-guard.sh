#!/bin/sh
# platform: host-agnostic
#   usage: compat-guard.sh BINARY DEFINED
#          tailscale's 10.9 compat guard for one binary: the floor, the SDK, no post-10.9 import, and each
#          of DEFINED (a grep -E alternation, e.g. _clock_gettime) defined in it. The Mach-O readers are
#          clang22's (build/fetch-clang22.sh) unless LIPO, OTOOL, NM and STRINGS already name others.
set -eu
[ $# -eq 2 ] || { echo "usage: compat-guard.sh BINARY DEFINED" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/build/msc.sh"
if [ -z "${LIPO:-}" ] || [ -z "${OTOOL:-}" ] || [ -z "${NM:-}" ] || [ -z "${STRINGS:-}" ]; then
  CL="$(sh "$REPO/build/fetch-clang22.sh")"
  LIPO="${LIPO:-$CL/bin/llvm-lipo}" OTOOL="${OTOOL:-$CL/bin/llvm-otool}"
  NM="${NM:-$CL/bin/llvm-nm}" STRINGS="${STRINGS:-$CL/bin/llvm-strings}"
fi
export LIPO OTOOL NM STRINGS
MAVERICKS_REQUIRE_DEFINED_SYMBOLS="$2" exec sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$1"
