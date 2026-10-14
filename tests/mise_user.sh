#!/bin/bash
#
# Personal mise layer test, run on the host against the dev image (needs
# network: it installs two small tools). In an interactive shell, as vscode:
#   - mise points at ~/.local/share/mise and sees none of the image's
#     manifests, and its shims come AFTER the image's tools on PATH;
#   - `versions` still reports the image's tools;
#   - `mise use -g` installs an extra tool into the home directory;
#   - an extra tool can't replace an image tool (the image's helm wins);
#   - nothing from the image's toolchain is downloaded again;
#   - only the trusted workspace folder's mise.toml is trusted.
#
# Usage: tests/mise_user.sh <dev image>

# Single-quoted $names are expanded by the container's zsh, not here.
# shellcheck disable=SC2016
set -euo pipefail

readonly EXTRA_TOOL="aqua:mikefarah/yq@4.44.3"
readonly SHADOW_TOOL="aqua:helm/helm@3.17.0"
readonly WORKSPACE="/workspaces/demo"
readonly DATA_DIR="/home/vscode/.local/share/mise"

# shellcheck source=scripts/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../scripts/lib/log.sh"

CONTAINER=""
FAILED=0

#######################################
# Run a command in an interactive zsh in the test container, as vscode.
# Globals:
#   CONTAINER
# Arguments:
#   The command (zsh source text).
# Outputs:
#   Its STDOUT and STDERR.
#######################################
in_zsh() {
  docker exec -u vscode -w /home/vscode "${CONTAINER}" zsh -i -c "$1" 2>&1
}

#######################################
# Record one check.
# Globals:
#   FAILED (set on failure)
# Arguments:
#   Description, then the command; the check passes when it succeeds.
# Outputs:
#   The result to STDERR.
#######################################
check() {
  local description="$1"
  shift
  if "$@"; then
    log::ok "${description}"
  else
    log::error "${description}"
    FAILED=1
  fi
}

#######################################
# Succeed when mise uses the home layer and none of the image's manifests.
#######################################
home_layer() {
  local got
  got="$(in_zsh 'print -r -- $MISE_DATA_DIR; mise config ls | wc -l')"
  [[ "${got}" == "${DATA_DIR}"$'\n0' ]]
}

#######################################
# Succeed when the shims folder comes after /usr/local/bin on PATH.
#######################################
shims_last() {
  local order
  order="$(in_zsh 'print -l $path' \
    | grep -nE '^(/usr/local/bin|/home/vscode/.local/share/mise/shims)$' \
    | cut -d: -f2 | tr '\n' ' ')"
  [[ "${order}" == "/usr/local/bin /home/vscode/.local/share/mise/shims " ]]
}

#######################################
# Succeed when `versions` in an interactive shell matches print-versions
# run outside it.
# Globals:
#   CONTAINER
#######################################
versions_unchanged() {
  local plain interactive
  plain="$(docker exec -u vscode "${CONTAINER}" print-versions)"
  interactive="$(in_zsh versions)"
  [[ -n "${plain}" && "${interactive}" == "${plain}" ]]
}

#######################################
# Succeed when an extra tool installs into the home layer and runs.
# Globals:
#   EXTRA_TOOL
#######################################
extra_tool_works() {
  in_zsh "mise use -g --yes ${EXTRA_TOOL}" >/dev/null
  local got
  got="$(in_zsh 'command -v yq; yq --version')"
  [[ "${got}" == "${DATA_DIR}/shims/yq"$'\n'*"4.44.3"* ]]
}

#######################################
# Succeed when an extra tool with an image tool's name doesn't replace it.
# Globals:
#   SHADOW_TOOL
#######################################
image_tool_wins() {
  in_zsh "mise use -g --yes ${SHADOW_TOOL}" >/dev/null
  [[ "$(in_zsh 'helm version --short')" == v4.* ]]
}

#######################################
# Succeed when the home layer holds only the two extra tools.
# Globals:
#   CONTAINER
#######################################
no_toolchain_download() {
  local installs
  installs="$(docker exec -u vscode "${CONTAINER}" \
    ls /home/vscode/.local/share/mise/installs | sort | tr '\n' ' ')"
  [[ "${installs}" == "aqua-helm-helm aqua-mikefarah-yq " ]]
}

#######################################
# Succeed when a mise.toml in the workspace is trusted only while
# MISE_TRUSTED_CONFIG_PATHS names that folder (as the template sets it).
# The file has [env]: mise asks for trust for such features (env, hooks,
# tasks), not for a list of tools.
# Globals:
#   CONTAINER, WORKSPACE
#######################################
workspace_trust() {
  local trusted untrusted
  docker exec -u root "${CONTAINER}" bash -c "mkdir -p ${WORKSPACE} \
    && printf '[env]\nDEMO_TRUSTED = \"yes\"\n' >${WORKSPACE}/mise.toml \
    && chown -R vscode ${WORKSPACE}"
  trusted="$(docker exec -u vscode -w "${WORKSPACE}" \
    -e MISE_TRUSTED_CONFIG_PATHS="${WORKSPACE}" "${CONTAINER}" \
    zsh -i -c 'mise env' 2>&1 || true)"
  untrusted="$(docker exec -u vscode -w "${WORKSPACE}" "${CONTAINER}" \
    zsh -i -c 'mise env' 2>&1 || true)"
  [[ "${trusted}" == *"DEMO_TRUSTED=yes"* && "${trusted}" != *"not trusted"* &&
    "${untrusted}" == *"not trusted"* ]]
}

#######################################
# Remove the test container.
# Globals:
#   CONTAINER
#######################################
cleanup() {
  if [[ -n "${CONTAINER}" ]]; then
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  fi
}

main() {
  local image="${1:-}"
  if [[ -z "${image}" ]]; then
    log::fatal "usage: tests/mise_user.sh <dev image>"
  fi
  CONTAINER="$(docker run -d --rm "${image}" sleep 600)"
  trap cleanup EXIT

  check "interactive mise uses ~/.local/share/mise, no image manifests" \
    home_layer
  check "its shims come after the image's tools on PATH" shims_last
  check "versions still reports the image's tools" versions_unchanged
  check "mise use -g installs an extra tool into the home layer" \
    extra_tool_works
  check "an extra tool can't replace an image tool (image helm wins)" \
    image_tool_wins
  check "nothing from the image's toolchain is downloaded again" \
    no_toolchain_download
  check "only the trusted workspace folder's mise.toml is trusted" \
    workspace_trust
  return "${FAILED}"
}

main "$@"
