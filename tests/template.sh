#!/bin/bash
#
# End-to-end test of the consumer repository template (template/): render it
# with the dev image under test, bring it up with the Dev Containers CLI (the
# engine VS Code uses), and check what a developer gets: the lifecycle hooks
# ran and the container is ready, Docker works, the time zone falls back to
# UTC, and dev.sh's --status and --shell work from the host and refuse
# inside the container.
#
# Usage: tests/template.sh [dev image]  (default: toolchain/dev:local; needs
# Docker and Node.js on the host. Skipped inside a dev container: the CLI's
# bind mounts would name paths that only exist in the container.)

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly CLI="@devcontainers/cli@0.80.1"
readonly WORK="${REPO_DIR}/.tmp/template-test"
readonly PROJECT="${WORK}/my-project"
# Seconds for each `up` attempt: the image is local, so a healthy one takes
# seconds; the retry gets longer.
readonly -a UP_TIMEOUTS=(120 300)
FAILED=0

# shellcheck source=scripts/lib/log.sh
source "${REPO_DIR}/scripts/lib/log.sh"

#######################################
# Record one check.
# Globals:
#   FAILED
# Arguments:
#   Description, then a command; the check passes when it succeeds.
# Outputs:
#   An OK or ERROR line to STDERR.
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
# Succeed when a string matches an extended regular expression.
# Arguments:
#   String, regex.
#######################################
matches() {
  [[ "$1" =~ $2 ]]
}

#######################################
# Print the ID of the test project's container, if any.
# Globals:
#   PROJECT
# Outputs:
#   The container ID to STDOUT.
#######################################
container_id() {
  docker ps -aq --filter "label=devcontainer.local_folder=${PROJECT}"
}

#######################################
# Remove the test project's container and folder.
# Globals:
#   WORK
#######################################
cleanup() {
  local id
  id="$(container_id)"
  if [[ -n "${id}" ]]; then
    docker rm -f "${id}" >/dev/null
  fi
  rm -rf -- "${WORK}"
}

#######################################
# Bring the project up with the Dev Containers CLI. Tries twice: in some
# environments (seen on WSL) the CLI stalls right after creating the
# container, and a second `up` carries on from the existing container.
# Globals:
#   CLI, PROJECT, UP_TIMEOUTS, WORK
# Returns:
#   0 when the CLI reports success.
#######################################
devcontainer_up() {
  local -i attempt
  for attempt in 1 2; do
    if timeout "${UP_TIMEOUTS[attempt - 1]}" npx --yes "${CLI}" up \
      --workspace-folder "${PROJECT}" >"${WORK}/up-${attempt}.log" 2>&1 \
      && grep -q '"outcome":"success"' "${WORK}/up-${attempt}.log"; then
      return 0
    fi
    log::warn "devcontainer up attempt ${attempt} did not finish" \
      "(log: ${WORK}/up-${attempt}.log)"
  done
  return 1
}

main() {
  local image="${1:-toolchain/dev:local}"
  local id out
  if [[ -n "${CONTAINER_WORKSPACE_FOLDER:-}" ]]; then
    log::warn "skipped inside a dev container (bind mounts need host" \
      "paths); run it on the host"
    return 0
  fi
  cleanup
  trap cleanup EXIT
  mkdir -p "${WORK}"
  "${REPO_DIR}/scripts/render_template.sh" "${image}" "${PROJECT}"
  git -C "${PROJECT}" init -q -b main

  devcontainer_up || log::fatal "the template's container didn't come up"
  id="$(container_id)"

  out="$(docker exec -u vscode "${id}" dev-status)" || true
  check "the lifecycle hooks ran and the container is ready" \
    matches "${out}" $'^ready\n.*post-create +done.*\n.*post-start +done'
  out="$(docker exec -u vscode "${id}" \
    cat /home/vscode/.local/state/toolchain/lifecycle/post-start.log)"
  check "post-start found git and the host's Docker engine" \
    matches "${out}" "tool git.*"$'\n'".*docker engine"
  out="$(docker exec -u vscode "${id}" date +%Z)"
  check "the time zone falls back to UTC" matches "${out}" "^UTC$"

  out="$("${PROJECT}/dev.sh" --status 2>&1)" || true
  check "dev.sh --status finds the container from the host" \
    matches "${out}" "^ready"
  out="$(printf 'pwd\nid -un\n' | "${PROJECT}/dev.sh" --shell 2>&1)" || true
  check "dev.sh --shell opens a shell as vscode in the workspace" \
    matches "${out}" "/workspaces/my-project"$'\n'"vscode"
  out="$(docker exec -u vscode -e REMOTE_CONTAINERS=true \
    -w /workspaces/my-project "${id}" ./dev.sh --rebuild 2>&1)" || true
  check "dev.sh refuses host-only commands inside the container" \
    matches "${out}" "inside the dev container"

  return "${FAILED}"
}

main "$@"
