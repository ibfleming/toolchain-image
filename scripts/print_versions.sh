#!/bin/bash
#
# Print the image's pinned toolchain as sorted `tool=version` lines: the ci
# manifest, plus the dev-only manifest when present (dev image), plus Claude
# Code (pinned in the Dockerfile, not mise). Installed in the images as
# /usr/local/bin/print-versions.
#
# STDOUT is the data: the parity and smoke tests, /etc/toolchain/versions
# and the release notes all read it.

set -euo pipefail

readonly DEV_MANIFEST="/etc/mise/dev/mise.toml"
readonly CLAUDE_BIN="/usr/local/bin/claude"
# Installed versions of every tool in `mise ls --json` output.
# shellcheck disable=SC2016 # jq variables, not shell ones
readonly JQ_INSTALLED='to_entries[] | .key as $t | .value[]
  | select(.installed) | "\($t)=\(.version)"'

#######################################
# Print the installed tools of the active global mise config.
# Globals:
#   JQ_INSTALLED
# Outputs:
#   `tool=version` lines to STDOUT.
#######################################
list_mise() {
  mise ls --global --json | jq -r "${JQ_INSTALLED}"
}

#######################################
# Print every pinned tool, unsorted (mise also reads /etc/mise as system
# config, so ci tools can repeat in the dev listing).
# Globals:
#   DEV_MANIFEST
#   CLAUDE_BIN
# Outputs:
#   `tool=version` lines to STDOUT.
#######################################
list_all() {
  local claude_version
  list_mise
  if [[ -f "${DEV_MANIFEST}" ]]; then
    MISE_GLOBAL_CONFIG_FILE="${DEV_MANIFEST}" list_mise
  fi
  if [[ -x "${CLAUDE_BIN}" ]]; then
    claude_version="$("${CLAUDE_BIN}" --version)"
    echo "claude-code=${claude_version%% *}"
  fi
}

main() {
  cd /
  list_all | sort -u
}

main "$@"
