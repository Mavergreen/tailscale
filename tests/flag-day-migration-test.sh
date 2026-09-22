#!/bin/sh
# dist/scripts/{pre,post}install: the one-time migration off the ModernMavericks identity (flag day
# 2026-09-22). Runs the real scripts against a fake target volume, with launchctl/pkgutil/stat/mkdir
# stubbed so nothing touches the running system. DELETABLE together with the migration.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/flag-day-migration.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# Stubs: record every call, change nothing. stat reports no console user, so the per-user GUI steps
# (which act on the running session, not a volume) are skipped.
mkdir -p "$T/bin" "$T/scripts"
for c in launchctl pkgutil mkdir sudo defaults; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$T" > "$T/bin/$c"
done
printf '#!/bin/sh\necho 0\n' > "$T/bin/stat"
chmod +x "$T/bin/"*
cp "$here/../dist/scripts/preinstall" "$here/../dist/scripts/postinstall" "$T/scripts/"
: > "$T/scripts/stop-gui.sh"
# Stands in for the shared agent-load.sh: its own flag-day migration needs the postinstall's $3.
printf 'echo "agent-load target=$3" >> "%s/calls"\n' "$T" > "$T/scripts/agent-load.sh"

run() {  # script volume
  : > "$T/calls"
  PATH="$T/bin:$PATH" sh "$T/scripts/$1" /fake/tailscale.pkg "$2" "$2" || fail "$1 exited non-zero"
}

plist() {  # file program-path
  mkdir -p "$(dirname "$1")"
  printf '<plist><dict><key>ProgramArguments</key><array>\n<string>%s</string>\n</array></dict></plist>\n' "$2" > "$1"
}

V="$T/vol"
OLD_D="$V/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
OLD_S="$V/Library/LaunchAgents/com.tailscale.systray.plist"
OLD_U="$V/Library/LaunchAgents/com.tailscale.updatecheck.plist"
plist "$OLD_D" /usr/local/sbin/tailscaled
plist "$OLD_S" "/Applications/Mavericks Tailscale.app/Contents/MacOS/tailscale-systray"
plist "$OLD_U" "/Library/Application Support/ModernMavericks/TailscaleUpdater.app/Contents/MacOS/TailscaleUpdater"
mkdir -p "$V/Library/Tailscale"; echo state > "$V/Library/Tailscale/tailscaled.state"

run preinstall "$V"
! grep -q 'com\.tailscale\.' "$T/calls" \
  || fail "preinstall unloaded an old job for a volume that is not the boot volume: $(cat "$T/calls")"
[ -f "$OLD_D" ] || fail "preinstall removed the old daemon plist; a failed install would leave no daemon at all"

run postinstall "$V"
[ ! -e "$OLD_D" ] || fail "left our old com.tailscale.tailscaled LaunchDaemon -- the old daemon would come back at boot beside the new one"
[ ! -e "$OLD_S" ] || fail "left our old com.tailscale.systray LaunchAgent -- two menu-bar icons at next login"
[ ! -e "$OLD_U" ] || fail "left our old com.tailscale.updatecheck LaunchAgent -- two daily update checks"
grep -qx "pkgutil --volume $V --forget dev.modernmavericks.tailscale" "$T/calls" \
  || fail "did not forget the old dev.modernmavericks.tailscale receipt on the target volume: $(cat "$T/calls")"
grep -qx "agent-load target=$V" "$T/calls" \
  || fail "agent-load.sh was not sourced with the target volume as \$3; the shared updater retirement would do nothing"
[ "$(cat "$V/Library/Tailscale/tailscaled.state")" = state ] || fail "touched the daemon's state"
grep -q 'launchctl load -w /Library/LaunchDaemons/dev.mavergreen.tailscaled.plist' "$T/calls" \
  || fail "did not load the daemon under its new label"

# Upstream's `tailscaled install-system-daemon` writes the same daemon label for ITS binary: not ours.
V2="$T/vol2"
plist "$V2/Library/LaunchDaemons/com.tailscale.tailscaled.plist" /usr/local/bin/tailscaled
plist "$V2/Library/LaunchAgents/com.tailscale.updatecheck.plist" /somewhere/else
run postinstall "$V2"
[ -f "$V2/Library/LaunchDaemons/com.tailscale.tailscaled.plist" ] \
  || fail "removed upstream's own install-system-daemon plist -- only ours may go"
[ -f "$V2/Library/LaunchAgents/com.tailscale.updatecheck.plist" ] \
  || fail "removed a com.tailscale.updatecheck agent that is not ours"

# No target volume: nothing known about where the old install lives, so nothing is removed.
V3="$T/vol3"
plist "$V3/Library/LaunchDaemons/com.tailscale.tailscaled.plist" /usr/local/sbin/tailscaled
( cd "$V3" && : > "$T/calls" && PATH="$T/bin:$PATH" sh "$T/scripts/postinstall" ) || fail "postinstall with no args exited non-zero"
[ -f "$V3/Library/LaunchDaemons/com.tailscale.tailscaled.plist" ] || fail "with no target volume it still removed something"
! grep -q 'forget' "$T/calls" || fail "with no target volume it still forgot a receipt"

echo "flag-day migration OK"
