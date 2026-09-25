#!/bin/sh
# platform: macOS-only -- launchctl stops tailscaled and the menu-bar agents before the tree is replaced
if [ -z "$ROOT" ]; then
  launchctl unload /Library/LaunchDaemons/dev.mavergreen.tailscaled.plist 2>/dev/null || true
  _uid=$(stat -f %u /dev/console 2>/dev/null || echo 0)
  if [ "${_uid:-0}" -gt 0 ]; then
    for _a in dev.mavergreen.tailscale-systray dev.mavergreen.tailscale-updatecheck; do
      launchctl asuser "$_uid" launchctl unload "/Library/LaunchAgents/$_a.plist" 2>/dev/null || true
    done
  fi
fi
