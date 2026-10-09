#!/bin/sh
# platform: macOS-only -- runs the built tailscale binaries, as root, on a real Mac OS X 10.9
# What our patches change, exercised on a real 10.9. CI runs it on a Mavergreen/mavericks-vm guest
# (ci.yml's on-mavericks job); it runs as well on any 10.9 box:
#   sudo sh tests/on-mavericks.sh <dir holding tailscaled, tailscale, tailscale-systray, osrouter.test>
# A build leaves them in its gobin/ ($MAVERICKS_BUILD_ROOT/<checkout>-<preset>/gobin). Step 4 briefly
# sends this machine's traffic into a tunnel nothing reads. Exits 77 (SKIP) off 10.9, when not root,
# or without the binaries. POSIX /bin/sh.
set -eu
sw="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
case "$sw" in 10.9*) : ;; *) echo "not 10.9 ($sw) -- skipping"; exit 77;; esac
BIN=${1:-}
for b in tailscaled tailscale tailscale-systray osrouter.test; do
  if [ -z "$BIN" ] || [ ! -x "$BIN/$b" ]; then echo "no $b in '$BIN' -- skipping"; exit 77; fi
done
[ "$(id -u)" = 0 ] || { echo "not root -- skipping"; exit 77; }

# A Unix socket's path is limited to 104 bytes, so the work dir stays short.
work=$(mktemp -d /tmp/tsom.XXXXXX)
sock=$work/s
pid=
fail() {
  echo "FAIL: $1" >&2
  if [ -s "$work/tailscaled.log" ]; then
    echo "--- tailscaled.log, last 40 lines:" >&2; tail -n 40 "$work/tailscaled.log" >&2
  fi
  exit 1
}
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; fi
  rm -rf "$work"
}
trap cleanup EXIT

# within SECS CMD...: CMD's status, or 124 once it has run SECS seconds (10.9 has no timeout(1)).
# The CLI waits indefinitely for a daemon that isn't answering, so every call to it goes through here.
# POSIX sh has no locals, so its variables are _-prefixed to stay clear of the callers'.
within() {
  _secs=$1; shift
  "$@" &
  _w=$!; _n=0
  while kill -0 "$_w" 2>/dev/null; do
    if [ "$_n" -ge "$_secs" ]; then kill "$_w" 2>/dev/null || :; wait "$_w" 2>/dev/null || :; return 124; fi
    sleep 1; _n=$((_n + 1))
  done
  wait "$_w"
}

echo "== 1. the binaries load and run on $sw"
within 20 "$BIN/tailscale" version > "$work/out" 2>&1 || { cat "$work/out"; fail "tailscale version"; }
cat "$work/out"
within 20 "$BIN/tailscaled" --version > "$work/out" 2>&1 || { cat "$work/out"; fail "tailscaled --version"; }
grep -q 'go version' "$work/out" || { cat "$work/out"; fail "tailscaled --version printed no go version"; }
within 20 "$BIN/tailscale-systray" -h > "$work/out" 2>&1 || { cat "$work/out"; fail "tailscale-systray -h"; }
grep -q -- '-socket' "$work/out" || { cat "$work/out"; fail "tailscale-systray -h printed no usage"; }

echo "== 2. hostinfo reports this OS version (hostinfo_darwin.go.patch)"
within 20 "$BIN/tailscale" debug hostinfo > "$work/out" 2>&1 || { cat "$work/out"; fail "tailscale debug hostinfo"; }
grep -q "\"OSVersion\": \"$sw\"" "$work/out" || { cat "$work/out"; fail "hostinfo's OSVersion is not $sw"; }
echo "OSVersion $sw"

echo "== 3. tailscaled runs as root on a utun, and stops cleanly"
before=" $(ifconfig -l) "
"$BIN/tailscaled" --statedir="$work/state" --socket="$sock" --port=0 --no-logs-no-support \
  > "$work/tailscaled.log" 2>&1 &
pid=$!
n=0
until [ -S "$sock" ] && within 10 "$BIN/tailscale" --socket="$sock" status --json > "$work/out" 2>/dev/null \
    && grep -q '"BackendState": "NeedsLogin"' "$work/out"; do
  kill -0 "$pid" 2>/dev/null || fail "tailscaled exited"
  [ "$n" -lt 60 ] || fail "tailscaled did not reach NeedsLogin in 60s"
  sleep 1; n=$((n + 1))
done
utun=
for i in $(ifconfig -l); do
  case "$before" in *" $i "*) continue;; esac
  case "$i" in utun*) utun=$i;; esac
done
[ -n "$utun" ] || fail "tailscaled made no utun"
echo "tailscaled is up on $utun, waiting for login"
if grep -E 'route (add|del) failed|addr (add|del) failed|router: .*(error|fail)' "$work/tailscaled.log"; then
  fail "the router logged failures"
fi
kill "$pid" || fail "tailscaled was already gone"
n=0
while kill -0 "$pid" 2>/dev/null; do
  [ "$n" -lt 30 ] || fail "tailscaled did not exit within 30s of SIGTERM"
  sleep 1; n=$((n + 1))
done
pid=
case " $(ifconfig -l) " in *" $utun "*) fail "$utun outlived tailscaled";; esac
echo "tailscaled stopped, and $utun went with it"

echo "== 4. the exit-node code, on this kernel (darwin-exit-nodes.patch)"
export TS_TEST_LIVE_ROUTES=1
status=0
within 120 "$BIN/osrouter.test" -test.run '^TestDarwin' -test.v > "$work/out" 2>&1 || status=$?
cat "$work/out"
[ "$status" -eq 0 ] || fail "the exit-node tests exited $status"
if grep -- '--- SKIP' "$work/out"; then fail "a test skipped: on a 10.9 guest as root, every one must run"; fi
echo "OK: everything ran on $sw"
