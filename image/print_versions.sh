#!/bin/bash
#
# Print the image's pinned toolchain as sorted `tool=version` lines: the ci
# manifest, plus the dev and shell manifests when present (dev image).
# Installed in the images as /usr/local/bin/print-versions.
#
# STDOUT is the data: the parity and smoke tests, /etc/toolchain/versions
# and the release notes all read it.

set -euo pipefail

# The image's mise (see the Dockerfile's ENV). Set here, not inherited: an
# interactive shell points mise at the user's own layer instead (zsh
# conf.d/05-mise-user), and `versions` must still report the image's tools.
readonly IMAGE_MISE_DATA_DIR="/opt/mise"
readonly IMAGE_MISE_CACHE_DIR="/var/cache/mise"
readonly CI_MANIFEST="/etc/mise/mise.toml"
# Optional manifests: present in the dev image only.
readonly -a EXTRA_MANIFESTS=(
  /etc/mise/dev/mise.toml
  /etc/mise/shell/mise.toml
)
# Installed versions of every tool in `mise ls --json` output.
# shellcheck disable=SC2016 # jq variables, not shell ones
readonly JQ_INSTALLED='to_entries[] | .key as $t | .value[]
  | select(.installed) | "\($t)=\(.version)"'

#######################################
# Print the installed tools of one of the image's mise manifests.
# Globals:
#   JQ_INSTALLED, IMAGE_MISE_DATA_DIR, IMAGE_MISE_CACHE_DIR
# Arguments:
#   The manifest (global config file).
# Outputs:
#   `tool=version` lines to STDOUT.
#######################################
list_mise() {
  MISE_DATA_DIR="${IMAGE_MISE_DATA_DIR}" \
    MISE_CACHE_DIR="${IMAGE_MISE_CACHE_DIR}" \
    MISE_GLOBAL_CONFIG_FILE="$1" \
    mise ls --global --json | jq -r "${JQ_INSTALLED}"
}

#######################################
# Print every pinned tool, unsorted (mise also reads /etc/mise as system
# config, so ci tools can repeat in the dev listing).
# Globals:
#   CI_MANIFEST, EXTRA_MANIFESTS
# Outputs:
#   `tool=version` lines to STDOUT.
#######################################
list_all() {
  local manifest
  list_mise "${CI_MANIFEST}"
  for manifest in "${EXTRA_MANIFESTS[@]}"; do
    if [[ -f "${manifest}" ]]; then
      list_mise "${manifest}"
    fi
  done
}

main() {
  cd /
  list_all | sort -u
}

main "$@"
