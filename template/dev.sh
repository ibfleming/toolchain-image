#!/bin/sh
#
# One command from a fresh clone to a ready dev container: open this
# repository in VS Code inside its dev container, wait until the container
# is ready, or open a shell in it from this terminal.
#
# Usage: ./dev.sh [COMMAND]
#   (none)     open in VS Code, in the container, and wait until it's ready
#   --shell    open a shell in the running container, in this terminal
#   --rebuild  remove the container, then open in VS Code (creates a new one;
#              a window still open on it asks to reload: choose Reload)
#   --status   print the container's lifecycle state (dev-status)
#   -h|--help  this help
#
# Needs on the host: Docker, and VS Code with the Dev Containers extension
# (its `code` command on PATH). Linux, macOS and Windows (WSL2).
#
# POSIX sh, not bash: macOS still ships bash 3.2 as /bin/bash.

set -eu

readonly CONTAINER_USER=vscode
readonly WAIT_SECONDS=900
readonly DEV_CONTAINERS_URL=https://code.visualstudio.com/docs/devcontainers

#######################################
# Print a message.
# Arguments:
#   Message words.
# Outputs:
#   The message to STDERR.
#######################################
info() {
  printf 'dev.sh: %s\n' "$*" >&2
}

#######################################
# Print an error and exit.
# Arguments:
#   Message words.
# Outputs:
#   The message to STDERR.
#######################################
die() {
  printf 'dev.sh: %s\n' "$*" >&2
  exit 1
}

#######################################
# Print the usage (the header comment's Usage block).
# Outputs:
#   The usage to STDOUT.
#######################################
usage() {
  sed -n '/^# Usage:/,/^#   -h/s/^# \{0,1\}//p' "$0"
}

#######################################
# Succeed when this runs inside a container (a dev container's terminal)
# rather than on the host.
# Globals:
#   REMOTE_CONTAINERS, CODESPACES
#######################################
in_container() {
  [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${CODESPACES:-}" ] \
    || [ -f /.dockerenv ]
}

#######################################
# Explain that a command needs the host, and exit.
# Arguments:
#   What to do inside the container instead.
#######################################
host_only() {
  die "this terminal is inside the dev container; run ./dev.sh on the" \
    "host (your WSL, Linux or macOS terminal). In here: $1"
}

#######################################
# Check that Docker is installed and its engine reachable.
#######################################
check_docker() {
  command -v docker >/dev/null 2>&1 \
    || die "Docker is not installed: install Docker Desktop (Windows, macOS)" \
      "or Docker Engine (Linux, or inside WSL2)"
  docker info >/dev/null 2>&1 \
    || die "Docker is installed but not reachable: start it (Docker" \
      "Desktop, or 'sudo systemctl start docker'), and check that your user" \
      "may use it ('docker info')"
}

#######################################
# Check that VS Code's `code` command is available.
#######################################
check_code() {
  command -v code >/dev/null 2>&1 \
    || die "VS Code's 'code' command is not on PATH: install VS Code and the" \
      "Dev Containers extension ($DEV_CONTAINERS_URL); on macOS, run 'Shell" \
      "Command: Install code command in PATH' from VS Code"
}

#######################################
# Print this folder the way VS Code's Dev Containers extension names it. On
# WSL, VS Code runs on Windows and sees the folder as a UNC path.
# Globals:
#   WSL_DISTRO_NAME, PWD
# Outputs:
#   The folder to STDOUT.
#######################################
host_folder() {
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    printf '\\\\wsl.localhost\\%s' "$WSL_DISTRO_NAME"
    # shellcheck disable=SC1003 # tr reads '\\' as one backslash
    printf '%s' "$PWD" | tr / '\\'
  else
    printf '%s' "$PWD"
  fi
}

#######################################
# Print a string as lowercase hex, two digits per byte.
# Arguments:
#   String.
# Outputs:
#   The hex to STDOUT.
#######################################
hex() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

#######################################
# Print the ID of this folder's dev container, if there is one.
# Globals:
#   PWD
# Arguments:
#   "-a" to include stopped containers, or nothing.
# Outputs:
#   The container ID to STDOUT, or nothing.
#######################################
find_container() {
  for folder in "$PWD" "$(host_folder)"; do
    id="$(docker ps -q ${1:+"$1"} \
      --filter "label=devcontainer.local_folder=$folder" | head -n 1)"
    if [ -n "$id" ]; then
      printf '%s' "$id"
      return 0
    fi
  done
}

#######################################
# Print where this folder is mounted in a container.
# Globals:
#   PWD
# Arguments:
#   Container ID.
# Outputs:
#   The container path to STDOUT.
#######################################
workspace_in() {
  format='{{range .Mounts}}{{if eq .Source "'"$PWD"'"}}'
  format="$format{{.Destination}}{{end}}{{end}}"
  dir="$(docker inspect -f "$format" "$1")"
  printf '%s' "${dir:-/workspaces/${PWD##*/}}"
}

#######################################
# Open this folder in VS Code, inside its dev container. VS Code builds or
# reuses the container and runs its lifecycle hooks.
# Globals:
#   PWD
#######################################
open_in_code() {
  uri="vscode-remote://dev-container+$(hex "$(host_folder)")"
  uri="$uri/workspaces/${PWD##*/}"
  info "opening VS Code in the dev container"
  code --folder-uri "$uri"
}

#######################################
# Wait until the container exists, then until its lifecycle says ready.
# Reports progress every 30 seconds while there's no container yet.
# Globals:
#   WAIT_SECONDS, CONTAINER_USER
#######################################
wait_ready() {
  waited=0
  id="$(find_container)"
  if [ -z "$id" ]; then
    info "waiting for VS Code to create the container (the first time" \
      "pulls the image, which takes a while)"
  fi
  while [ -z "$id" ]; do
    [ "$waited" -lt "$WAIT_SECONDS" ] \
      || die "no container after ${WAIT_SECONDS}s; check VS Code's" \
        "Dev Containers log (Dev Containers: Show Container Log)"
    sleep 2
    waited=$((waited + 2))
    if [ $((waited % 30)) -eq 0 ]; then
      info "still no container after ${waited}s. VS Code should show" \
        "'Starting Dev Container'; if no VS Code window opened, or it" \
        "asks to reload, close it and run ./dev.sh again"
    fi
    id="$(find_container)"
  done
  if docker exec -u "$CONTAINER_USER" "$id" dev-wait -t "$WAIT_SECONDS"; then
    info "ready: work in VS Code, or run './dev.sh --shell' for a" \
      "terminal here"
  else
    docker exec -u "$CONTAINER_USER" "$id" dev-status >&2 || true
    die "the container is not ready; see above, and VS Code's Dev" \
      "Containers log"
  fi
}

#######################################
# Open a login shell in the running container, in this terminal, with the
# SSH agent VS Code forwards (if a VS Code window is attached).
# Globals:
#   CONTAINER_USER
#######################################
open_shell() {
  id="$(find_container)"
  if [ -z "$id" ]; then
    if command -v devcontainer >/dev/null 2>&1; then
      info "starting the dev container (devcontainer CLI)"
      devcontainer up --workspace-folder . >/dev/null
      id="$(find_container)"
    fi
    [ -n "$id" ] || die "the dev container isn't running: run ./dev.sh first"
  fi
  dir="$(workspace_in "$id")"
  login="$(docker exec "$id" getent passwd "$CONTAINER_USER" | cut -d: -f7)"
  sock="$(docker exec "$id" sh -c \
    'ls -t /tmp/vscode-ssh-auth-*.sock 2>/dev/null | head -n 1' || true)"
  set -- -i -u "$CONTAINER_USER" -w "$dir"
  if [ -t 0 ] && [ -t 1 ]; then
    set -- "$@" -t
  fi
  if [ -n "$sock" ]; then
    set -- "$@" -e "SSH_AUTH_SOCK=$sock"
  fi
  exec docker exec "$@" "$id" "${login:-/bin/bash}" -l
}

#######################################
# Remove this folder's dev container (running or not). A VS Code window
# still open on it loses its connection and asks to reload; reloading
# creates the new container. (Whether a window is open can't be told
# reliably: VS Code's server keeps running in the container after the
# window closes.)
#######################################
remove_container() {
  id="$(find_container -a)"
  if [ -n "$id" ]; then
    info "removing the dev container $id (volumes are kept); if VS Code" \
      "has it open, choose 'Reload Window' when it asks"
    docker rm -f "$id" >/dev/null
  fi
}

main() {
  # The repository root is where this script lives.
  cd "$(dirname -- "$0")"
  [ -f .devcontainer/devcontainer.json ] \
    || die "no .devcontainer/devcontainer.json next to dev.sh"
  if in_container; then
    case "${1:-}" in
      --status) exec dev-status ;;
      -h | --help) ;;
      --shell) host_only "you already have a shell" ;;
      --rebuild) host_only "run 'Dev Containers: Rebuild Container'" ;;
      *) host_only "you're already in the container ('dev-status')" ;;
    esac
  fi
  case "${1:-}" in
    "")
      check_docker
      check_code
      open_in_code
      wait_ready
      ;;
    --shell)
      check_docker
      open_shell
      ;;
    --rebuild)
      check_docker
      check_code
      remove_container
      open_in_code
      wait_ready
      ;;
    --status)
      check_docker
      id="$(find_container)"
      [ -n "$id" ] || die "the dev container isn't running: run ./dev.sh"
      exec docker exec -u "$CONTAINER_USER" "$id" dev-status
      ;;
    -h | --help)
      usage
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
}

main "$@"
