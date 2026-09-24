#!/bin/sh
# prepare_sdk106.sh — assemble the 10.6-floor sysroot: the toolchain's verified
# MacOSX10.9 SDK (fetched/cached by its own fetch_sdk.sh) plus our assembled
# crt1.10.6.o (from overlays/legacy106/crt106.S) in usr/lib, where ld searches.
# Prints the sdk106 root. Cached per-machine; rebuilt if inputs change.
#
# The stamp fingerprints BOTH inputs: the source SDK path and the sha256 of
# crt106.S (so editing the startup source rebuilds the object), and the crt
# object's presence is re-verified every call.
#
# Locking: the CC wrapper runs this from every parallel cgo compile, so the
# rebuild is guarded by a mkdir lock with the ownership PID recorded INSIDE
# the lock dir (where no competitor can overwrite it). Protocol: (a) only
# the owner removes its own lock (EXIT trap); (b) a dead holder's lock is
# broken via kill -0 on the recorded PID; (c) the mkdir-to-echo gap is
# covered by patient waiting (empty lock = holder is mid-stamp), with a
# long-timeout fallback for a holder killed exactly in the gap; (d) the
# need-check re-runs inside the acquired lock so a waiter that slept
# through the previous holder's completion does not rebuild a fresh tree.
#
#   $1 = go toolchain prefix (for libexec/fetch_sdk.sh)
#   $2 = repo root (for overlays/legacy106/crt106.S)
set -eu
PREFIX="$1"; ROOT="$2"
CACHE="${MAVERICKS_SDK106_CACHE:-$HOME/Library/Caches/mavericks-sdk106}"
SDK109="$(sh "$PREFIX/libexec/fetch_sdk.sh")"
CRT_SRC="$ROOT/overlays/legacy106/crt106.S"
CRT_SHA="$(shasum -a 256 "$CRT_SRC" | cut -d' ' -f1)"

# Key the cache path on the input hash so concurrent builds using
# DIFFERENT toolchain/SDK/crt inputs never collide on the same directory
# (a build with input A must not rm -rf the sysroot a build with input B
# just assembled and is actively using).
INPUT_KEY=$(printf '%s\n%s' "$SDK109" "$CRT_SHA" | shasum -a 256 | cut -c1-16)
SDK="$CACHE/sdk106-$INPUT_KEY"
STAMP="$SDK/.legacy106-stamp"
LOCK="$CACHE/.sdk106-$INPUT_KEY.lock"

satisfied() {
  [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SDK109:$CRT_SHA" ] \
    && [ -f "$SDK/usr/lib/crt1.10.6.o" ]
}

if satisfied; then
  echo "$SDK"
  exit 0
fi

mkdir -p "$CACHE"
i=0; lock_err=0
until mkdir "$LOCK" 2>/dev/null; do
  # Distinguish 'lock exists' from 'cannot create'. If the lock no longer
  # exists (a competitor just finished), retry; only fail on persistent
  # permission/filesystem errors.
  if [ ! -d "$LOCK" ]; then
    sleep 1   # give a finishing competitor's cleanup a moment
    [ -d "$LOCK" ] && continue  # was a race; retry acquisition
    # Still gone after sleep: could be permissions OR another race.
    # Retry up to 3 times, then fail (persistent filesystem error).
    lock_err=$((lock_err + 1))
    if [ "$lock_err" -gt 3 ]; then
      echo "prepare_sdk106: cannot create lock ${LOCK} (persistent error)" >&2
      exit 1
    fi
    continue
  fi
  lock_err=0
  if [ -f "$LOCK/pid" ]; then
    # Ownership record exists: break only if the holder process is dead.
    # (Edge case: PID reuse could make a dead holder look alive; accepted
    # risk on macOS where PIDs cycle slowly.)
    HOLDER_PID=$(cat "$LOCK/pid" 2>/dev/null || echo 0)
    if [ "${HOLDER_PID:-0}" -gt 0 ] && ! kill -0 "$HOLDER_PID" 2>/dev/null; then
      # Atomically CLAIM the stale lock by renaming it (only ONE process
      # can rename a given directory; the loser's mv fails and it goes
      # back to waiting). The old rm -rf approach raced: two waiters could
      # both remove the stale lock, then one would delete the OTHER's
      # freshly-acquired lock, and both would rebuild concurrently.
      # Fall through to timeout+sleep on failure (a bare 'continue' would
      # skip both, causing a busy loop when the rename persistently fails).
      if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
        rm -rf "$LOCK.stale.$$" 2>/dev/null || true
        continue
      fi
    fi
  fi
  # Empty lock (holder in the mkdir-to-echo gap): WAIT, do not evict.
  # Evicting an unowned lock can break a live holder that was paused
  # (SIGSTOP, debugger, swap) before writing its PID, leading to two
  # concurrent rebuilds. The general timeout (600s) handles the "killed
  # in the gap" case conservatively by failing the build rather than
  # risking concurrent access.
  i=$((i + 1))
  # 600s total: the empty-lock fallback needs 300 iterations to fire, so
  # the general timeout must exceed it (a 120s timeout would exit before
  # the fallback could ever trigger).
  if [ "$i" -gt 600 ]; then
    # NEVER evict the lock — even an empty one could be a live holder
    # paused (SIGSTOP, debugger, swap) in the mkdir-to-PID gap. Evicting
    # it would allow a second rebuild to rm -rf the sysroot under the
    # paused holder. Fail cleanly; a human can remove the lock manually.
    echo "prepare_sdk106: lock timeout (${LOCK})." >&2
    echo "prepare_sdk106: if no other build is running, remove ${LOCK} manually." >&2
    exit 1
  fi
  sleep 1
done

# Lock acquired -- stamp ownership immediately (nanoseconds after mkdir;
# the empty-lock patience above covers this gap for waiters).
trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT
echo $$ > "$LOCK/pid"

# Re-check INSIDE the lock: a waiter that slept through the previous holder's
# completion would otherwise rebuild (and rm -rf) the tree it just built.
if satisfied; then
  echo "$SDK"
  exit 0
fi

rm -rf "$SDK"
cp -R "$SDK109" "$SDK"
/usr/bin/clang -arch x86_64 -mmacosx-version-min=10.6 -c \
  "$CRT_SRC" -o "$SDK/usr/lib/crt1.10.6.o"
echo "$SDK109:$CRT_SHA" > "$STAMP"
echo "$SDK"
