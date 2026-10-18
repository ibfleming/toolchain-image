#!/bin/bash
#
# Make sure a GitHub-hosted runner has enough free disk for the images
# (about 2 GB each, exported again by Trivy), deleting preinstalled SDKs only
# when it doesn't. Deleting them takes a minute or two, and the runners
# usually have room to spare, so the check comes first.
#
# Usage: free_disk.sh [GIGABYTES]  (default 15; the free space wanted on /)

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly DEFAULT_WANTED_GB=15
# Deleted in this order, until there's room: quick to delete first.
readonly -a REMOVABLE=(
  /usr/share/dotnet
  /opt/hostedtoolcache/CodeQL
  /opt/ghc
  /usr/local/lib/android
)

# shellcheck source=image/lib/log.sh
source "${REPO_DIR}/image/lib/log.sh"

#######################################
# Print the free space on / in whole gigabytes.
# Outputs:
#   The number to STDOUT.
#######################################
free_gb() {
  df --output=avail -BG / | tail -n 1 | tr -dc '0-9'
}

main() {
  local wanted="${1:-${DEFAULT_WANTED_GB}}"
  local dir
  [[ "${wanted}" =~ ^[0-9]+$ ]] || log::fatal "usage: free_disk.sh [GIGABYTES]"
  for dir in "${REMOVABLE[@]}"; do
    if (($(free_gb) >= wanted)); then
      break
    fi
    if [[ -d "${dir}" ]]; then
      log::info "$(free_gb) GB free, ${wanted} wanted: deleting ${dir}"
      sudo rm -rf -- "${dir}"
    fi
  done
  if (($(free_gb) < wanted)); then
    log::fatal "only $(free_gb) GB free after cleaning up; ${wanted} wanted"
  fi
  log::ok "$(free_gb) GB free (${wanted} wanted)"
}

main "$@"
