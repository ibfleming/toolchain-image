#!/bin/bash
#
# postCreateCommand: runs once, when the container is created. Install the
# project's dependencies and bootstrap it here; anything to repeat on every
# start belongs in post-start.sh. Uses the image's lifecycle library, so
# `dev-status` shows how it went.

set -euo pipefail

# shellcheck source=/dev/null # in the toolchain image
source /usr/local/lib/toolchain/lifecycle.sh

#######################################
# Install the project's dependencies, from whichever lock files it has.
# Replace or extend this for your project.
# Outputs:
#   The package managers' output.
#######################################
install_dependencies() {
  local found=0
  if [[ -f pnpm-lock.yaml ]]; then
    pnpm install --frozen-lockfile
    found=1
  elif [[ -f package-lock.json ]]; then
    npm ci
    found=1
  fi
  if [[ -f uv.lock ]]; then
    uv sync --frozen
    found=1
  fi
  if [[ -f go.mod ]]; then
    go mod download
    found=1
  fi
  if ((found == 0)); then
    log::info "no lockfile found; nothing to install"
  fi
}

#######################################
# Everything post-create does. Steps in lifecycle::once run once per
# container; `dev-reset <name>` makes them run again.
#######################################
bootstrap() {
  lifecycle::once dependencies install_dependencies
}

main() {
  lifecycle::stage post-create bootstrap
}

main "$@"
