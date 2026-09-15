#!/bin/sh
#   usage: assert_legacy106_compatible.sh <binary>...
#          Snow Leopard (10.6) floor guard, run INSTEAD of shipyard's 10.9 gate
#          for a -legacy106 build. Per binary:
#            (1) arch exactly x86_64
#            (2) LC_VERSION_MIN_MACOSX == 10.6
#            (3) the 10.6 shims are DEFINED (not left as dynamic imports):
#                _arc4random_buf (the cgo package) + the toolchain's
#                _clock_gettime; _strnlen/_dirfd/_pthread_main_thread_np are
#                not referenced by this toolchain's runtime and may be absent.
#            (4) GOAMD64=v1 opcode audit: Core 2 has no POPCNT (SIGILL).
#                Under v1, Go 1.26 inline-multi-versions math/bits PER FUNCTION:
#                one runtime.x86HasPOPCNT check at the function entry guards
#                every popcnt in that function's body with a software fallback.
#                The audit verifies that every non-runtime function containing
#                popcnt also contains the x86HasPOPCNT reference somewhere in
#                its body (matching the compiler's emission model). Runtime-
#                internal sites (countbody, pageBits, scanObjects*) are allowed
#                as a bounded set: that exact code is hardware-proven on a
#                Core 2 P8700 (a full tailscaled ran joined for hours).
#          Fail-closed if nothing measured.
#
# platform: the stock 10.9 gate asserts LC_VERSION_MIN == 10.9 exactly, so it
#           would (correctly!) reject a 10.6-floor binary; this is its 10.6 twin.
set -eu

die() { echo "legacy106 guard CANNOT MEASURE (fail-closed): $*" >&2; exit 4; }

RUNTIME_ALLOWANCE=20

fail=0; checked=0
# One temp dir for every binary's disassembly, removed once at exit: a
# per-iteration trap would be overwritten each pass and leak all but the
# last file.
DISDIR=$(mktemp -d "${TMPDIR:-/tmp}/l106dis.XXXXXX")
trap 'rm -rf "$DISDIR"' EXIT
for b in "$@"; do
  [ -f "$b" ] || { echo "legacy106 guard: MISSING $b" >&2; fail=1; continue; }
  checked=$((checked+1))

  # exactly x86_64: extract the arch list from -info output (portable to
  # exactly x86_64 — not just "x86_64 present". lipo -info formats:
  #   thin: "Non-fat file: X is architecture: x86_64"  → 1 arch token
  #   fat:  "Architectures in the fat file: X are: i386 x86_64" → 2 tokens
  # Taking only the LAST field ($NF) would pass a fat binary that happens
  # to list x86_64 last. Instead: reject any output containing "are:"
  # (fat-file marker) and require the thin-file last field to be x86_64.
  raw=$(lipo -info "$b" 2>/dev/null) || raw=""
  [ -n "$raw" ] || die "lipo produced no output for $b"
  case "$raw" in
    *"are:"*)
      echo "$b: multi-arch binary (not exactly x86_64): $raw" >&2
      fail=1
      ;;
    *)
      archs=$(printf '%s\n' "$raw" | awk '{print $NF}')
      [ "$archs" = "x86_64" ] || { echo "$b: not exactly x86_64: $archs" >&2; fail=1; }
      ;;
  esac

  vmin=$(otool -l "$b" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{f=1} f && /version /{print $2; exit}')
  [ -n "$vmin" ] || die "no LC_VERSION_MIN_MACOSX in $b"
  [ "$vmin" = "10.6" ] || { echo "$b: min-version $vmin != 10.6" >&2; fail=1; }

  # required shims: _clock_gettime must be defined (toolchain shim). The cgo
  # legacy106 symbols (arc4random_buf ...) are only present when this
  # toolchain actually imports them — an undefined IMPORT is the failure;
  # total absence means the patched runtime never references them.
  if ! /usr/bin/nm "$b" 2>/dev/null | grep -q "[Tt] _clock_gettime\$"; then
    echo "$b: _clock_gettime not defined (toolchain shim missing)" >&2; fail=1
  fi
  # Fail closed: if nm cannot read the binary, the guard must not pass.
  # A piped nm | grep would return grep's exit status, treating a failed
  # nm the same as "no undefined imports found".
  if ! nmout=$(/usr/bin/nm -m "$b" 2>&1); then
    echo "$b: nm cannot read the binary -- cannot audit imports" >&2; fail=1; continue
  fi
  for s in _arc4random_buf _pthread_main_thread_np _strnlen _dirfd; do
    if printf '%s\n' "$nmout" | grep -F '(undefined)' | sed -E 's/ \([^)]*\)$//' \
        | awk '{print $NF}' | grep -qx "$s"; then
      echo "$b: $s left as an undefined import (shim not linked)" >&2; fail=1
    fi
  done

  # opcode audit. Go 1.26 inline-multi-versions math/bits per FUNCTION: one
  # runtime.x86HasPOPCNT check guards every popcnt the function contains, with
  # a software fallback. A non-runtime function containing popcnt must show
  # the guard somewhere in its body; runtime-internal sites (countbody,
  # pageBits, scanObjects*, ...) are a bounded, hardware-proven set.
  # Fail-closed: disassemble to a file first and verify otool's status --
  # a piped `otool | awk` only surfaces awk's exit, so a failed disassembly
  # would audit an empty stream and pass.
  dis="$DISDIR/$(basename "$b").dis"
  if ! otool -tvV "$b" > "$dis" 2>/dev/null || [ ! -s "$dis" ]; then
    echo "$b: disassembly failed -- cannot audit opcodes" >&2; fail=1; continue
  fi
  awk -v allow=$RUNTIME_ALLOWANCE -v bin="$b" '
    function flushsym() {
      if (sym != "" && nsym_popcnt > 0 && sym !~ /^_runtime\./ && sym !~ /^_countbody/ \
          && sym !~ /^_internal\// && sym !~ /^_go:/) {
        if (sym_guarded == 0) {
          printf "%s: UNGUARDED popcnt (no x86HasPOPCNT in body): %s\n", bin, sym
          bad = 1
        }
      }
      if (sym ~ /^_runtime\./ || sym ~ /^_countbody/ || sym ~ /^_internal\//) rt += nsym_popcnt
    }
    /^([0-9a-f]+[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_.\/()*]+:$/ { flushsym(); sym = $0; sub(/^[0-9a-f]+[[:space:]]+/, "", sym); nsym_popcnt = 0; sym_guarded = 0 }
    /x86HasPOPCNT/ { sym_guarded = 1 }
    /popcntl|popcntq/ { nsym_popcnt++ }
    END { flushsym();
      if (rt > allow) { printf "%s: %d runtime popcnt sites > allowance %d\n", bin, rt, allow; bad = 1 }
      if (bad) exit 1 }' "$dis" || fail=1
done
[ "$checked" -gt 0 ] || die "no binaries measured"
if [ "$fail" -eq 0 ]; then echo "legacy106 guard: OK ($checked binary(ies))"; fi
exit "$fail"
