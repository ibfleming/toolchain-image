#!/bin/bash
#
# devcontainer.metadata test, run on the host: the dev image's label is what
# a consuming repository's dev container starts from, and anyone who can
# pull the image can read it. Checks that it parses, sets up vscode, holds
# nothing that could carry a secret (no remoteEnv or containerEnv), lists
# well-formed extension IDs and points at a command that exists in the
# image; and that ci, which is no dev container, has no such label.
#
# Usage: tests/devcontainer_metadata.sh <ci image> <dev image>

set -euo pipefail

readonly LABEL=devcontainer.metadata
REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR

# shellcheck source=image/lib/log.sh
source "${REPO_DIR}/image/lib/log.sh"

FAILED=0

#######################################
# Print an image's devcontainer.metadata label, or nothing.
# Arguments:
#   Image.
# Outputs:
#   The label to STDOUT.
#######################################
label_of() {
  docker image inspect "$1" \
    --format "{{ index .Config.Labels \"${LABEL}\" }}"
}

#######################################
# Check one jq condition against the metadata.
# Globals:
#   FAILED (set on failure)
# Arguments:
#   Description, the metadata JSON, a jq filter that must print true.
# Outputs:
#   The result to STDERR.
#######################################
check() {
  local description="$1"
  local metadata="$2"
  local filter="$3"
  if [[ "$(jq -r "${filter}" <<<"${metadata}")" == true ]]; then
    log::ok "${description}"
  else
    log::error "${description}"
    FAILED=1
  fi
}

main() {
  local ci_image="${1:-}"
  local dev_image="${2:-}"
  local metadata command
  if [[ -z "${ci_image}" || -z "${dev_image}" ]]; then
    log::fatal "usage: tests/devcontainer_metadata.sh <ci image> <dev image>"
  fi

  if [[ -z "$(label_of "${ci_image}")" ]]; then
    log::ok "ci has no ${LABEL} label"
  else
    log::error "ci has a ${LABEL} label: it is no dev container"
    FAILED=1
  fi

  metadata="$(label_of "${dev_image}")"
  if ! jq -e 'type == "array" and length > 0' <<<"${metadata}" \
    >/dev/null 2>&1; then
    log::fatal "dev: ${LABEL} is not a non-empty JSON array: '${metadata}'"
  fi
  check "remoteUser is vscode" "${metadata}" \
    '[.[] | .remoteUser // empty] | last == "vscode"'
  check "no remoteEnv or containerEnv (readable by anyone who can pull)" \
    "${metadata}" 'all(.[]; has("remoteEnv") or has("containerEnv") | not)'
  check "extension IDs are publisher.name, lowercase" "${metadata}" \
    '[.[].customizations.vscode.extensions // [] | .[]]
      | length > 0 and all(test("^[a-z0-9-]+\\.[a-z0-9-]+$"))'

  # The postStartCommand runs in every consumer's container: its program must
  # exist there (after `sudo`, if the command uses it).
  command="$(jq -r '[.[] | .postStartCommand // empty] | last // ""' \
    <<<"${metadata}")"
  command="${command#sudo }"
  command="${command%% *}"
  if [[ -z "${command}" ]]; then
    log::ok "no postStartCommand"
  elif docker run --rm --network none "${dev_image}" test -x "${command}"; then
    log::ok "postStartCommand ${command} is executable in the image"
  else
    log::error "postStartCommand ${command} is missing or not executable"
    FAILED=1
  fi
  return "${FAILED}"
}

main "$@"
