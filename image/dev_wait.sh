#!/bin/bash
#
# Wait until the dev container is ready (or a lifecycle stage fails), for
# scripts and terminals that start before the container finishes setting
# up. Installed in the dev image as /usr/local/bin/dev-wait.
#
# Usage: dev-wait [-t|--timeout SECONDS]  (default 600; 0 waits forever)
#
# Exit status: 0 ready, 1 failed, 2 timed out, 64 bad usage.

set -euo pipefail

# shellcheck source=image/lib/lifecycle.sh
source /usr/local/lib/toolchain/lifecycle.sh

readonly DEFAULT_TIMEOUT=600

main() {
  local timeout="${DEFAULT_TIMEOUT}"
  local -i deadline announced=0
  case "${1:-}" in
    "") ;;
    -t | --timeout)
      timeout="${2:-}"
      ;;
    *) timeout="" ;;
  esac
  # Decimal without a leading zero (bash reads "08" as bad octal), at most
  # nine digits (no overflow).
  if [[ ! "${timeout}" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
    echo "usage: dev-wait [-t|--timeout SECONDS]" >&2
    return 64
  fi
  deadline=$((SECONDS + timeout))
  while true; do
    lifecycle::state
    case "${REPLY}" in
      ready) return 0 ;;
      failed)
        log::error "a lifecycle stage failed; run dev-status"
        return 1
        ;;
    esac
    if ((timeout > 0 && SECONDS >= deadline)); then
      log::error "not ready after ${timeout}s (state: ${REPLY})"
      return 2
    fi
    if ((announced == 0)); then
      log::info "waiting for the container to be ready (state: ${REPLY})"
      announced=1
    fi
    sleep 1
  done
}

main "$@"
