#!/bin/bash
#
# Print the dev container's lifecycle state: overall, then each stage and
# step, from the markers that scripts/lib/lifecycle.sh writes. Installed in
# the dev image as /usr/local/bin/dev-status.
#
# Usage: dev-status [-q|--quiet]
#   -q, --quiet  print only the overall state
#
# Exit status: 0 ready, 1 failed, 2 anything else (created, bootstrapping,
# partial), 64 bad usage.

set -euo pipefail

# shellcheck source=scripts/lib/lifecycle.sh
source /usr/local/lib/toolchain/lifecycle.sh

#######################################
# Print one line per recorded stage and step.
# Arguments:
#   State directory.
# Outputs:
#   Lines to STDOUT.
#######################################
print_details() {
  local dir="$1"
  local file name
  for file in "${dir}"/*.started; do
    [[ -f "${file}" ]] || continue
    name="${file##*/}"
    name="${name%.started}"
    if [[ -f "${dir}/${name}.failed" ]]; then
      printf '  ✗ %-14s failed   %s (log: %s)\n' "${name}" \
        "$(<"${dir}/${name}.failed")" "${dir}/${name}.log"
    elif [[ -f "${dir}/${name}.done" ]]; then
      printf '  ✓ %-14s done     %s\n' "${name}" "$(<"${dir}/${name}.done")"
    else
      printf '  … %-14s running  since %s\n' "${name}" "$(<"${file}")"
    fi
  done
  for file in "${dir}"/*.done; do
    [[ -f "${file}" ]] || continue
    name="${file##*/}"
    name="${name%.done}"
    [[ -f "${dir}/${name}.started" ]] && continue
    printf '  ✓ %-14s once     %s\n' "${name}" "$(<"${file}")"
  done
}

main() {
  local quiet=0 dir state
  case "${1:-}" in
    "") ;;
    -q | --quiet) quiet=1 ;;
    *)
      echo "usage: dev-status [-q|--quiet]" >&2
      return 64
      ;;
  esac
  lifecycle::dir
  dir="${REPLY}"
  lifecycle::state
  state="${REPLY}"
  echo "${state}"
  if ((quiet == 0)); then
    print_details "${dir}"
  fi
  case "${state}" in
    ready) return 0 ;;
    failed) return 1 ;;
    *) return 2 ;;
  esac
}

main "$@"
