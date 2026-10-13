#!/bin/bash
#
# Docker outside of Docker, run on the host: with the host's socket mounted
# at /var/run/docker-host.sock (as the devcontainer.json template does),
# docker-socket-init lets vscode use the host engine through
# /var/run/docker.sock. It must also be idempotent, and do nothing without a
# host socket.
#
# Usage: tests/docker_socket.sh <dev image>
# Needs a local Docker engine at /var/run/docker.sock.

set -euo pipefail

readonly HOST_SOCKET="/var/run/docker.sock"

# shellcheck source=scripts/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../scripts/lib/log.sh"

CONTAINER=""
FAILED=0

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
# Run a command in the test container as vscode, discarding its output.
# Globals:
#   CONTAINER
# Arguments:
#   The command and its arguments.
#######################################
as_vscode() {
  docker exec -u vscode "${CONTAINER}" "$@" >/dev/null 2>&1
}

#######################################
# Succeed when vscode cannot reach a Docker engine yet.
#######################################
no_access_yet() {
  ! as_vscode docker version
}

#######################################
# Succeed when exactly one socat proxy is running.
# Globals:
#   CONTAINER
#######################################
one_proxy() {
  local count
  count="$(docker exec -u root "${CONTAINER}" \
    pgrep -c -f 'socat UNIX-LISTEN')"
  [[ "${count}" == 1 ]]
}

#######################################
# Succeed when vscode talks to the same engine as the host.
# Globals:
#   CONTAINER
#######################################
same_engine() {
  local want got
  want="$(docker version --format '{{.Server.Version}}')"
  got="$(docker exec -u vscode "${CONTAINER}" \
    docker version --format '{{.Server.Version}}' 2>&1 || true)"
  [[ -n "${want}" && "${got}" == "${want}" ]]
}

#######################################
# Succeed when the buildx and compose plugins load for vscode.
#######################################
plugins_load() {
  as_vscode docker buildx version && as_vscode docker compose version
}

#######################################
# Succeed when docker-socket-init does nothing in a container without a
# host socket.
# Arguments:
#   Dev image.
#######################################
noop_without_socket() {
  docker run --rm -u root "$1" \
    bash -c 'docker-socket-init && [[ ! -e /var/run/docker.sock ]]' \
    >/dev/null 2>&1
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
    log::fatal "usage: tests/docker_socket.sh <dev image>"
  fi
  CONTAINER="$(docker run -d --rm \
    -v "${HOST_SOCKET}:/var/run/docker-host.sock" "${image}" sleep 300)"
  trap cleanup EXIT

  check "no access before docker-socket-init" no_access_yet
  docker exec -u root "${CONTAINER}" docker-socket-init
  docker exec -u root "${CONTAINER}" docker-socket-init # a second start
  check "idempotent: one proxy after two runs" one_proxy
  check "vscode uses the host engine" same_engine
  check "buildx and compose plugins load" plugins_load
  check "no host socket: does nothing" noop_without_socket "${image}"
  return "${FAILED}"
}

main "$@"
