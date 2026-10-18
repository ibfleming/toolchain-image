#!/bin/bash
#
# Make the host's Docker engine usable by the dev user ("Docker outside of
# Docker"). Installed in the dev image as /usr/local/sbin/docker-socket-init.
#
# devcontainer.json mounts the host's socket at /var/run/docker-host.sock.
# This runs as root on every container start (the image metadata's
# postStartCommand) and serves that socket at /var/run/docker.sock, owned by
# group `docker` (which vscode is in), through a socat proxy. A proxy, not
# chown/chmod: the mounted socket is the host's own file, and its owner
# varies by platform (root on Docker Desktop, a host-specific group on
# Linux).
#
# Does nothing without a host socket: none mounted, or Docker-in-Docker owns
# /var/run/docker.sock.

set -euo pipefail

readonly HOST_SOCK="/var/run/docker-host.sock"
readonly SOCK="/var/run/docker.sock"
# Root-only directory: in world-writable /tmp, another user could plant a file
# or link at this path before root writes to it.
readonly PROXY_LOG="/var/log/docker-socket-proxy.log"

# shellcheck source=image/lib/log.sh
source "${TOOLCHAIN_LIB_DIR:-/usr/local/lib/toolchain}/log.sh"

#######################################
# Whether the proxy is already serving SOCK (a second start of the same
# container).
# Globals:
#   SOCK
# Returns:
#   0 if serving, 1 otherwise.
#######################################
proxy_running() {
  [[ -S "${SOCK}" ]] && pgrep -f "socat UNIX-LISTEN:${SOCK}" >/dev/null
}

#######################################
# Start the socat proxy in its own session, detached from every stream (a
# lifecycle command's caller waits for open pipes), and wait up to 5 s for
# its socket.
# Globals:
#   HOST_SOCK
#   SOCK
#   PROXY_LOG
# Outputs:
#   socat's own messages go to PROXY_LOG.
# Returns:
#   0 once SOCK exists, 1 on timeout.
#######################################
start_proxy() {
  rm -f "${SOCK}"
  nohup setsid socat \
    "UNIX-LISTEN:${SOCK},fork,mode=0660,user=root,group=docker" \
    "UNIX-CONNECT:${HOST_SOCK}" \
    </dev/null >"${PROXY_LOG}" 2>&1 &
  for _ in {1..50}; do
    [[ -S "${SOCK}" ]] && return 0
    sleep 0.1
  done
  return 1
}

main() {
  [[ -S "${HOST_SOCK}" ]] || return 0
  if proxy_running; then
    return 0
  fi
  if ! start_proxy; then
    log::fatal "the proxy did not start, see ${PROXY_LOG}"
  fi
  log::info "serving the host's Docker engine at ${SOCK}"
}

main "$@"
