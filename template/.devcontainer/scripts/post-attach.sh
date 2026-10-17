#!/bin/bash
#
# postAttachCommand: runs each time VS Code attaches. Information only: the
# container's state and the usual sign-ins. Never fails, never changes state.

set -euo pipefail

# shellcheck source=/dev/null # in the toolchain image
source /usr/local/lib/toolchain/validate.sh

main() {
  dev-status || true
  validate::sign_ins
}

main "$@"
