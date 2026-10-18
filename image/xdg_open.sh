#!/bin/bash
#
# Open a URL on your machine from the dev container. Installed in the dev
# image as /usr/local/bin/xdg-open, for tools that open a browser (gh auth
# login, OAuth sign-ins, documentation links):
#
#   - In a VS Code terminal, $BROWSER is VS Code's helper, which opens the
#     URL in your machine's browser.
#   - Elsewhere (./dev.sh --shell, SSH), the URL is printed and copied to
#     your clipboard (see xclip), so you can paste it into your browser.
#
# Usage: xdg-open URL

set -euo pipefail

# shellcheck source=image/lib/log.sh
source /usr/local/lib/toolchain/log.sh

main() {
  local url="${1:-}"
  if [[ -z "${url}" || $# -gt 1 ]]; then
    log::error "usage: xdg-open URL"
    return 64
  fi
  if [[ -n "${BROWSER:-}" && -x "${BROWSER%% *}" ]] \
    && "${BROWSER}" "${url}" >/dev/null 2>&1; then
    return 0
  fi
  log::info "open this in your browser: ${url}"
  if printf '%s' "${url}" | xclip -selection clipboard 2>/dev/null; then
    log::info "(copied to your clipboard)"
  fi
}

main "$@"
