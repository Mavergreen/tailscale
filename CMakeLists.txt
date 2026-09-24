cmake_minimum_required(VERSION 3.15)

project(mavericks_tailscale LANGUAGES NONE)
# LANGUAGES NONE: nothing is compiled by CMake here. The real 10.9/x86_64 enforcement is the go build
# flags + the compat_guard gate. The ObjC Sparkle updater is built by shipyard's stage_updater.sh.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9)
set(CMAKE_OSX_ARCHITECTURES x86_64)

# Build mode. "native" = building ON Mavericks 10.9 with the mavericks-golang go126 .pkg
# (/usr/local/go126, whose go.env ships the CC wrapper: 10.9 SDK + target flags + legacy shim +
# -Wl,-U weak-symbol allowances). "cross" = a modern host with the go126-cross toolchain on PATH.
# native REQUIRES the .pkg toolchain (its go.env wrapper), NOT pkgsrc go126 (wrapper not upstreamed there).
set(MAVERICKS_TAILSCALE_MODE "cross")
set(MAVERICKS_TAILSCALE_NATIVE_GO "")
if(EXISTS "/usr/local/go126/bin/go")
  execute_process(COMMAND sw_vers -productVersion
    OUTPUT_VARIABLE _osv OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  if(_osv MATCHES "^10\\.9\\.")
    set(MAVERICKS_TAILSCALE_MODE "native")
    set(MAVERICKS_TAILSCALE_NATIVE_GO "/usr/local/go126/bin/go")
  endif()
endif()
message(STATUS "mavericks-tailscale ${MAVERICKS_TAILSCALE_VERSION} — build: ${MAVERICKS_TAILSCALE_MODE}")

# Require a per-mode preset so a build never lands in an ambiguous build/ dir (native vs cross).
if(NOT DEFINED MAVERICKS_TAILSCALE_EXPECTED_MODE)
  message(FATAL_ERROR
    "Configure via a preset: 'cmake --preset native' on Mavericks, or "
    "'cmake --preset cross' on a modern host. Direct 'cmake -B <dir>' is disabled.")
endif()
if(NOT MAVERICKS_TAILSCALE_EXPECTED_MODE STREQUAL MAVERICKS_TAILSCALE_MODE)
  message(FATAL_ERROR "preset expects a '${MAVERICKS_TAILSCALE_EXPECTED_MODE}' build but this machine "
    "does a '${MAVERICKS_TAILSCALE_MODE}' build — wrong preset for this host.")
endif()

# Shared machinery: compat_guard + the (later) updater/sign/floor scripts. The 10.9 SDK, target flags,
# and legacy shim are supplied by the go126 toolchain's default CC wrapper (its go.env).
find_package(MavericksShipyard REQUIRED)

# The product version (feeds the .pkg name + the release tag). NOT passed to project(VERSION ...): the
# mavericks scheme (1.102.0-mavericks.9) is not a valid CMake version.
#
# Derived, never committed: UPSTREAM_VERSION (written by build/derive-upstream-version.sh from the
# pinned source's own VERSION.txt) plus the shipped tags decide it. The committed VERSION this
# replaces still said 1.98.8-mavericks.1 while releases were at 1.102.0 -- two upstreams stale.
mavericks_resolve_version(MAVERICKS_TAILSCALE_VERSION)

# The Go compiler: the native go126 .pkg on the box, or go126-cross on PATH for a cross build.
if(MAVERICKS_TAILSCALE_MODE STREQUAL "native")
  set(MAVERICKS_TAILSCALE_GO "${MAVERICKS_TAILSCALE_NATIVE_GO}")
else()
  set(MAVERICKS_TAILSCALE_GO "go")
endif()

set(MAVERICKS_TAILSCALE_SRC_CACHE "${CMAKE_SOURCE_DIR}/.srccache" CACHE PATH
    "Shared cache dir for the pinned tailscale source clone")

include(ExternalProject)
enable_testing()

include(cmake/tailscale_go.cmake)   # cross-builds tailscaled / tailscale / tailscale-systray + compat_guard

# Release notes link upstream's changelog entry, which is anchored by date: prove the lookup against
# a fixture shaped like the real page (no network).
add_test(NAME upstream_release_notes_url
  COMMAND sh "${CMAKE_SOURCE_DIR}/tests/upstream-release-notes-url-test.sh")
