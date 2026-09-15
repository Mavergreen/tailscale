# Cross-build tailscaled / tailscale / tailscale-systray for darwin/amd64 min-10.9 with the
# ModernMavericks go126 toolchain, then compat_guard each. Source = the pinned upstream
# tailscale/tailscale release tag (the 10.9 story is entirely the go126 toolchain + our patches/overlays,
# so no fork is needed); our vendored subset (patches/ source tweaks + overlays/ third-party-module
# 10.9-SDK shims) is applied by build_tailscale.sh, which does all heavy work on LOCAL disk (repo on NFS).

# Read the tailscale source pin (Renovate-tracked, components-style: components/tailscale/version).
# DIGEST (the commit sha) is what clone_pinned.sh verifies the checkout against; REF is the human label.
function(mavericks_tailscale_read_pin dir out_repo out_ref out_digest)
  file(STRINGS "${dir}/version" _lines)
  foreach(_l IN LISTS _lines)
    if(_l MATCHES "^REPO=(.+)$")
      set(_repo "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^REF=(.+)$")
      set(_ref "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^DIGEST=(.+)$")
      set(_digest "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  set(${out_repo}   "${_repo}"   PARENT_SCOPE)
  set(${out_ref}    "${_ref}"    PARENT_SCOPE)
  set(${out_digest} "${_digest}" PARENT_SCOPE)
endfunction()

mavericks_tailscale_read_pin("${CMAKE_SOURCE_DIR}/components/tailscale" TS_REPO TS_REF TS_DIGEST)
set(TS_SRC "${MAVERICKS_TAILSCALE_SRC_CACHE}/tailscale-${TS_REF}")

# Deployment floor: 10.9 (default, stock gate) or 10.6 (Snow Leopard: GOAMD64=v1 +
# 10.6 symbol archive + min-10.6 CC wrapper + the legacy106 gate). Preset sets this.
set(MAVERICKS_TAILSCALE_FLOOR "10.9" CACHE STRING "macOS deployment floor: 10.9 or 10.6")
if(NOT MAVERICKS_TAILSCALE_FLOOR MATCHES "^10\\.(9|6)$")
  message(FATAL_ERROR "MAVERICKS_TAILSCALE_FLOOR must be 10.9 or 10.6, got '${MAVERICKS_TAILSCALE_FLOOR}'")
endif()

# The custom command's outputs are floor-independent paths, so re-pointing an existing build
# directory at the other floor would silently test/package the previous floor's binaries
# (same outputs, dependencies unchanged -> no rebuild). Fail closed instead: each build dir
# records its floor at first configure and refuses a different one. Presets use separate
# dirs (build-cross / build-cross-legacy) and never trip this.
set(_floor_marker "${CMAKE_BINARY_DIR}/.tailscale-floor")
if(EXISTS "${_floor_marker}")
  file(READ "${_floor_marker}" _recorded)
  string(STRIP "${_recorded}" _recorded)
  if(NOT _recorded STREQUAL MAVERICKS_TAILSCALE_FLOOR)
    message(FATAL_ERROR "this build dir was configured for floor ${_recorded}; "
      "changing MAVERICKS_TAILSCALE_FLOOR to ${MAVERICKS_TAILSCALE_FLOOR} here would reuse stale "
      "floor-${_recorded} binaries. Configure a fresh build dir (the presets do: build-cross vs "
      "build-cross-legacy).")
  endif()
else()
  # First configure: reject a pre-marker dir that already has binaries (they
  # are from a different floor and would be silently reused as stale outputs).
  if(EXISTS "${CMAKE_BINARY_DIR}/gobin/tailscaled")
    message(FATAL_ERROR "this build dir contains existing binaries but no floor "
      "marker -- they may be from a different floor. Delete the build dir and "
      "reconfigure (the presets use fresh dirs: build-cross vs build-cross-legacy).")
  endif()
  file(WRITE "${_floor_marker}" "${MAVERICKS_TAILSCALE_FLOOR}\n")
endif()

# 1. Clone the pinned source, verified against the commit DIGEST (shipyard's clone_pinned.sh bails
#    on a mismatch -- moved tag, MITM). Idempotent: no-ops on a cache hit.
add_custom_command(
  OUTPUT "${TS_SRC}/.git/HEAD"
  COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh" "${TS_REPO}" "${TS_REF}" "${TS_DIGEST}" "${TS_SRC}"
  COMMENT "cloning tailscale ${TS_REF}"
  VERBATIM)

# 2. Build the three binaries. Rebuilds when the script, our patches/overlays, or the pin change.
#
# Build-graph correctness: EVERYTHING build_tailscale.sh reads must be a dependency, and it reads
# all of patches/ and overlays/ (plus the legacy106 tooling). Two stale-binary bugs came from
# hand-maintaining this list (a new patch file; then legacy106.go), and a first glob attempt put
# the file() calls INSIDE add_custom_command where CMake silently swallows them as junk arguments
# (configure succeeds, nothing globs) -- so they run here, at their own statement level.
# LIST_DIRECTORIES false: GLOB_RECURSE includes directories by default (e.g. overlays/legacy106/),
# which make useless or broken DEPENDS entries (especially with Ninja).
# CONFIGURE_DEPENDS: a file()d glob is evaluated at generate time, so CMake re-runs generate on
# build when a matching file is added/removed -- the coverage actually tracks new patches.
file(GLOB_RECURSE MAVERICKS_TAILSCALE_PATCHES CONFIGURE_DEPENDS LIST_DIRECTORIES false "${CMAKE_SOURCE_DIR}/patches/*")
file(GLOB_RECURSE MAVERICKS_TAILSCALE_OVERLAYS CONFIGURE_DEPENDS LIST_DIRECTORIES false "${CMAKE_SOURCE_DIR}/overlays/*")
file(GLOB MAVERICKS_TAILSCALE_LEGACY106_TOOLS CONFIGURE_DEPENDS LIST_DIRECTORIES false "${CMAKE_SOURCE_DIR}/cmake/legacy106/*")
# CONFIGURE_DEPENDS re-globs on build, but a SHRINKING dependency list does
# not necessarily dirty the output (nothing that still exists changed). A
# manifest stamp does: any addition OR removal changes its content, which
# dirties the stamp file, which is an explicit dependency below.
set(MAVERICKS_TAILSCALE_INPUT_MANIFEST "${CMAKE_BINARY_DIR}/.tailscale-input-manifest")
# Write only when content changes: an unconditional file(WRITE) bumps the
# mtime on every configure, dirtying all outputs even when nothing changed.
set(_new_manifest "${MAVERICKS_TAILSCALE_PATCHES};${MAVERICKS_TAILSCALE_OVERLAYS};${MAVERICKS_TAILSCALE_LEGACY106_TOOLS}")
if(EXISTS "${MAVERICKS_TAILSCALE_INPUT_MANIFEST}")
  file(READ "${MAVERICKS_TAILSCALE_INPUT_MANIFEST}" _old_manifest)
  if(NOT _old_manifest STREQUAL _new_manifest)
    file(WRITE "${MAVERICKS_TAILSCALE_INPUT_MANIFEST}" "${_new_manifest}")
  endif()
else()
  file(WRITE "${MAVERICKS_TAILSCALE_INPUT_MANIFEST}" "${_new_manifest}")
endif()

set(TS_GOBIN "${CMAKE_BINARY_DIR}/gobin")
set(TS_BINS "${TS_GOBIN}/tailscaled" "${TS_GOBIN}/tailscale" "${TS_GOBIN}/tailscale-systray")
add_custom_command(
  OUTPUT ${TS_BINS}
  COMMAND sh "${CMAKE_SOURCE_DIR}/cmake/build_tailscale.sh"
             "${TS_SRC}" "${TS_GOBIN}" "${MAVERICKS_TAILSCALE_GO}"
             "${CMAKE_SOURCE_DIR}" "${MAVERICKS_TAILSCALE_VERSION}"
             "${MAVERICKS_TAILSCALE_FLOOR}"
  DEPENDS "${TS_SRC}/.git/HEAD"
          "${MAVERICKS_TAILSCALE_INPUT_MANIFEST}"
          "${CMAKE_SOURCE_DIR}/cmake/build_tailscale.sh"
          ${MAVERICKS_TAILSCALE_PATCHES}
          ${MAVERICKS_TAILSCALE_OVERLAYS}
          ${MAVERICKS_TAILSCALE_LEGACY106_TOOLS}
          "${CMAKE_SOURCE_DIR}/components/tailscale/version"
  COMMENT "cross-building tailscaled / tailscale / tailscale-systray for ${MAVERICKS_TAILSCALE_FLOOR}"
  VERBATIM)
add_custom_target(tailscale_binaries ALL DEPENDS ${TS_BINS})

# 3. Compat gate per binary. 10.9: the shipyard gate (x86_64 + min-10.9 + _clock_gettime
#    defined + no post-10.9 imports). 10.6: our legacy106 twin (min == 10.6, the 10.6 symbol
#    set defined, and a POPCNT site-count tripwire for the GOAMD64=v1 baseline).
foreach(_b tailscaled tailscale tailscale-systray)
  if(MAVERICKS_TAILSCALE_FLOOR STREQUAL "10.6")
    add_test(NAME legacy106_guard_${_b}
      COMMAND sh "${CMAKE_SOURCE_DIR}/tests/assert_legacy106_compatible.sh" "${TS_GOBIN}/${_b}")
  else()
    add_test(NAME compat_guard_${_b}
      COMMAND ${CMAKE_COMMAND} -E env MAVERICKS_REQUIRE_DEFINED_SYMBOLS=_clock_gettime
        sh "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh" "${TS_GOBIN}/${_b}")
  endif()
endforeach()
