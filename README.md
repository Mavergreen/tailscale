# Mavericks Tailscale

Tailscale for Mac OS X 10.9 (Mavericks): tailscaled, the `tailscale` CLI, and a menu-bar app, built
against the pinned 10.9 SDK with a Sparkle auto-updater. This is an unofficial community build, not
affiliated with or endorsed by Tailscale Inc.

Install via `mavergreen install tailscale` on a box with the `mavergreen` helper set up, or download
the `.pkg` from [Releases](https://github.com/Mavergreen/tailscale/releases).

## Upgrading a pre-install-layout install

This build's install layout changed: tailscaled's state moved to
`/usr/local/mavergreen/var/tailscale/tailscaled.state` (it was
`/Library/Tailscale/tailscaled.state`). There is no migration code carrying the old file over. The
new `.pkg`'s postinstall starts (or reloads) the daemon **immediately**, so if the old state file is
still where the daemon will not find it, the node comes up **ephemeral** and re-registers as a new
device on your tailnet.

If you have an install from before this change, move the state file **before** running the new
`.pkg`:

```sh
sudo mkdir -p -m 0700 /usr/local/mavergreen/var/tailscale
sudo mv /Library/Tailscale/tailscaled.state /usr/local/mavergreen/var/tailscale/tailscaled.state
sudo chmod 0600 /usr/local/mavergreen/var/tailscale/tailscaled.state
```

Alternatively, unload the daemon first, move the file, then reload it once the new `.pkg` is
installed:

```sh
sudo launchctl unload /Library/LaunchDaemons/dev.mavergreen.tailscaled.plist
sudo mkdir -p -m 0700 /usr/local/mavergreen/var/tailscale
sudo mv /Library/Tailscale/tailscaled.state /usr/local/mavergreen/var/tailscale/tailscaled.state
sudo chmod 0600 /usr/local/mavergreen/var/tailscale/tailscaled.state
sudo launchctl load -w /Library/LaunchDaemons/dev.mavergreen.tailscaled.plist
```
