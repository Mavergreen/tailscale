cmake_minimum_required(VERSION 3.16)
# Cocoa/Sparkle auto-updater .app for the Tailscale product. A SEPARATE project from the Go build
# (the repo root is project(... LANGUAGES NONE) and requires a preset); build it on its own with
# `shipyard-cmake -S updater -B build/updater`. Native only: the product .pkg installs on the real
# 10.9 box, so the updater is x86_64 / min-10.9. It links Sparkle + Cocoa and NOTHING from Tailscale
# (a Sparkle host carries no product code) -- the release workflow asserts that.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "updater runs on the 10.9 box")
set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only (10.9)")
project(TailscaleUpdater LANGUAGES OBJC)
find_package(MavericksShipyard REQUIRED)
include(Mavericks)          # AppleClang gate + build conventions
include(MavericksSparkle)   # the Sparkle updater .app builder
# Single-source the version from the repo root (this project's source dir is updater/). Derived from
# UPSTREAM_VERSION + the shipped tags, not read from a committed file.
mavericks_resolve_version(MAVERICKS_TAILSCALE_VERSION ROOT "${CMAKE_SOURCE_DIR}/..")
mavericks_add_updater_app(
  NAME TailscaleUpdater
  PRODUCT_NAME "Mavericks Tailscale"
  BUNDLE_ID dev.modernmavericks.TailscaleUpdater
  FEED_URL "https://github.com/ModernMavericks/tailscale/releases/latest/download/appcast.xml"
  ED_PUBKEY_FILE "${CMAKE_SOURCE_DIR}/ed25519_key.pub"
  ICON "${CMAKE_SOURCE_DIR}/../Tailscale.icns"   # shared product icon (also used by the menu-bar Mavericks Tailscale.app)
  VERSION "${MAVERICKS_TAILSCALE_VERSION}"
  LOG_PREFIX "MavTailscaleUpdater"
  CONFIRM_TITLE "Mavericks Tailscale updated"
  CONFIRM_BODY "The Tailscale daemon, CLI, and menu-bar app were updated; the daemon reloaded."
  RELAUNCH_MARKER "/tmp/.tailscale-updater-relaunched"
  # no PANE_HINT_KEY -> a background-found update posts an NSUserNotification (CLI/menu-bar product)
)
