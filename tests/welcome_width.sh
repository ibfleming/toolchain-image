#!/bin/bash
#
# Welcome box test, run on the host: the box's borders must line up whatever
# the rows hold. Renders `welcome` in the dev image with fake OS names and
# terminal widths, and checks that every line of the box has the same width
# (and that it fits the terminal).
#
# Usage: tests/welcome_width.sh <dev image>

set -euo pipefail

readonly LONG_NAME="Acme Enterprise Linux Server for Workstations 9.4.1"

# shellcheck source=scripts/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../scripts/lib/log.sh"

IMAGE=""
FAILED=0
WORK=""

#######################################
# Render the welcome box with a given OS name and terminal width.
# Globals:
#   IMAGE, WORK
# Arguments:
#   PRETTY_NAME for /etc/os-release, terminal columns.
# Outputs:
#   The box as plain text (no colors) to STDOUT.
#######################################
render() {
  local pretty="$1"
  local columns="$2"
  printf 'PRETTY_NAME="%s"\n' "${pretty}" >"${WORK}/os-release"
  docker run --rm -t -u vscode -e TERM=xterm-256color \
    -e COLUMNS="${columns}" -v "${WORK}/os-release:/etc/os-release:ro" \
    "${IMAGE}" zsh -i -c welcome \
    | tr -d '\r' \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -E '^[╭│├╰]'
}

#######################################
# Check one rendering: every box line equally wide, within the terminal,
# and containing an expected text.
# Globals:
#   FAILED (set on failure)
# Arguments:
#   Description, PRETTY_NAME, terminal columns, text that must appear.
# Outputs:
#   The result to STDERR.
#######################################
check() {
  local description="$1"
  local pretty="$2"
  local -i columns="$3"
  local want="$4"
  local box widths
  box="$(render "${pretty}" "${columns}")"
  widths="$(while IFS= read -r line; do echo "${#line}"; done \
    <<<"${box}" | sort -u)"
  if [[ "${widths}" =~ ^[0-9]+$ ]] && ((widths <= columns)) \
    && [[ "${box}" == *"${want}"* ]]; then
    log::ok "${description} (${widths} columns)"
  else
    log::error "${description}: line widths '${widths//$'\n'/ }'," \
      "terminal ${columns}, want '${want}'"
    printf '%s\n' "${box}" >&2
    FAILED=1
  fi
}

#######################################
# Remove the work directory.
# Globals:
#   WORK
#######################################
cleanup() {
  if [[ -n "${WORK}" ]]; then
    rm -rf "${WORK}"
  fi
}

main() {
  IMAGE="${1:-}"
  if [[ -z "${IMAGE}" ]]; then
    log::fatal "usage: tests/welcome_width.sh <dev image>"
  fi
  WORK="$(mktemp -d)"
  trap cleanup EXIT

  check "Debian keeps the 66-column box" \
    "Debian GNU/Linux 13 (trixie)" 100 "Debian 13 ·"
  check "Ubuntu: point release and LTS dropped, borders aligned" \
    "Ubuntu 24.04.5 LTS" 100 "Ubuntu 24.04 ·"
  check "a long row widens the whole box" \
    "${LONG_NAME}" 140 "Workstations 9.4 · x86_64"
  check "a narrow terminal cuts the row instead" \
    "${LONG_NAME}" 80 "…"
  return "${FAILED}"
}

main "$@"
