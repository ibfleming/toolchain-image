#!/bin/bash
#
# Clear the dev container's lifecycle state, so `lifecycle::once` steps run
# again the next time their stage runs. Installed in the dev image as
# /usr/local/bin/dev-reset.
#
# To run the stages now, run their scripts again in order, ending with the
# one that marks the container ready (for example
# .devcontainer/scripts/post-create.sh, then post-start.sh): starting any
# stage clears `ready`, so the container stays "partial" until then.
#
# Usage: dev-reset [MARKER...]  (no markers: clear everything)

set -euo pipefail

# shellcheck source=scripts/lib/lifecycle.sh
source /usr/local/lib/toolchain/lifecycle.sh

main() {
  local dir marker
  lifecycle::dir
  dir="${REPLY}"
  if (($# == 0)); then
    rm -rf "${dir}"
    log::ok "cleared all lifecycle state (${dir})"
    log::info "rebuild the container, or run every stage script again in" \
      "order"
    return 0
  fi
  for marker in "$@"; do
    if [[ "${marker}" == */* || -z "${marker}" ]]; then
      log::error "not a marker name: '${marker}'"
      return 64
    fi
    rm -f "${dir}/${marker}".{started,done,failed,log}
    log::ok "cleared ${marker}"
  done
  rm -f "${dir}/ready"
  log::info "run the stage scripts again (ending with the one that marks" \
    "the container ready), or restart the container"
}

main "$@"
