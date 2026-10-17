#!/bin/bash
#
# postStartCommand: runs on every start (after post-create.sh the first
# time). Check that the container has what the project needs, then mark it
# ready. Keep it quick: no installs here.

set -euo pipefail

# shellcheck source=/dev/null # in the toolchain image
source /usr/local/lib/toolchain/lifecycle.sh
# shellcheck source=/dev/null # in the toolchain image
source /usr/local/lib/toolchain/validate.sh

#######################################
# Readiness checks. Each failure logs how to fix it; validate::report fails
# the stage if any did. Add the project's own: tools, mounts, variables.
#######################################
checks() {
  local docker_hint="can't reach the host's Docker: is it running, and is"
  docker_hint+=" its socket mounted (devcontainer.json)?"
  validate::tool git
  validate::check "docker engine" "${docker_hint}" docker info
  # validate::env DATABASE_URL "set it in containerEnv in devcontainer.json"
  # validate::mount "${HOME}/.kube" "mount ~/.kube (devcontainer.json)"
  validate::report
}

main() {
  lifecycle::stage post-start checks
  lifecycle::ready
}

main "$@"
