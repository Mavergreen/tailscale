#!/bin/sh
# platform: macOS-only -- launchctl starts tailscaled and the menu-bar agent in the console user's session
_rc=0
mkdir -p -m 0700 "$ROOT/usr/local/mavergreen/var/tailscale" || _rc=1
mkdir -p "$ROOT/Library/Logs/Tailscale" || _rc=1
if [ -z "$ROOT" ]; then
  launchctl unload /Library/LaunchDaemons/dev.mavergreen.tailscaled.plist 2>/dev/null || true
  launchctl load -w /Library/LaunchDaemons/dev.mavergreen.tailscaled.plist 2>/dev/null || true
  _uid=$(stat -f %u /dev/console 2>/dev/null || echo 0)
  _user=$(stat -f %Su /dev/console 2>/dev/null || echo root)
  if [ "${_uid:-0}" -gt 0 ] && [ "$_user" != root ]; then
    launchctl asuser "$_uid" launchctl unload /Library/LaunchAgents/dev.mavergreen.tailscale-systray.plist 2>/dev/null || true
    . "$(dirname "$0")/stop-gui.sh"
    mav_stop_gui_instance 'Contents/MacOS/tailscale-systray' "$_uid"
    launchctl asuser "$_uid" launchctl load -w /Library/LaunchAgents/dev.mavergreen.tailscale-systray.plist 2>/dev/null || true
  fi
fi
[ "$_rc" -eq 0 ]
