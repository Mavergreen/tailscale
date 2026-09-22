# Cross-build tailscaled / tailscale / tailscale-systray for darwin/amd64 min-10.9 with the
# Mavergreen go126 toolchain, then compat_guard each. Source = the pinned upstream
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

# 1. Clone the pinned source, verified against the commit DIGEST (shipyard's clone_pinned.sh bails
#    on a mismatch -- moved tag, MITM). Idempotent: no-ops on a cache hit.
add_custom_command(
  OUTPUT "${TS_SRC}/.git/HEAD"
  COMMAND sh "${MavericksShipyard_SCRIPTS}/clone_pinned.sh" "${TS_REPO}" "${TS_REF}" "${TS_DIGEST}" "${TS_SRC}"
  COMMENT "cloning tailscale ${TS_REF}"
  VERBATIM)

# 2. Build the three binaries. Rebuilds when the script, our patches/overlays, or the pin change.
set(TS_GOBIN "${CMAKE_BINARY_DIR}/gobin")
set(TS_BINS "${TS_GOBIN}/tailscaled" "${TS_GOBIN}/tailscale" "${TS_GOBIN}/tailscale-systray")
add_custom_command(
  OUTPUT ${TS_BINS}
  COMMAND sh "${CMAKE_SOURCE_DIR}/cmake/build_tailscale.sh"
             "${TS_SRC}" "${TS_GOBIN}" "${MAVERICKS_TAILSCALE_GO}"
             "${CMAKE_SOURCE_DIR}" "${MAVERICKS_TAILSCALE_VERSION}"
  DEPENDS "${TS_SRC}/.git/HEAD"
          "${CMAKE_SOURCE_DIR}/cmake/build_tailscale.sh"
          "${CMAKE_SOURCE_DIR}/patches/systray.go.patch"
          "${CMAKE_SOURCE_DIR}/patches/tailscaled.go.patch"
          "${CMAKE_SOURCE_DIR}/patches/hostinfo_darwin.go.patch"
          "${CMAKE_SOURCE_DIR}/patches/darwin-exit-nodes.patch"
          "${CMAKE_SOURCE_DIR}/overlays/certstore_darwin.go.patch"
          "${CMAKE_SOURCE_DIR}/overlays/systray_darwin.m"
          "${CMAKE_SOURCE_DIR}/components/tailscale/version"
  COMMENT "cross-building tailscaled / tailscale / tailscale-systray for 10.9"
  VERBATIM)
add_custom_target(tailscale_binaries ALL DEPENDS ${TS_BINS})

# 3. Compat gate per binary: x86_64 + min-10.9 + _clock_gettime defined + no post-10.9 imports.
#    assert_binary_compatible.sh is the shipyard gate (honors MAVERICKS_REQUIRE_DEFINED_SYMBOLS);
#    the same script container-tools uses for its Go binaries.
foreach(_b tailscaled tailscale tailscale-systray)
  add_test(NAME compat_guard_${_b}
    COMMAND ${CMAKE_COMMAND} -E env MAVERICKS_REQUIRE_DEFINED_SYMBOLS=_clock_gettime
      sh "${MavericksShipyard_SCRIPTS}/assert_binary_compatible.sh" "${TS_GOBIN}/${_b}")
endforeach()
