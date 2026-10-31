#!/bin/bash
#
# Tests for scripts/release_notes.sh, with a fake docker: the builder's
# provenance commands run as printed, under a shell that rejects unmatched
# globs (as zsh does), and the toolchain table marks what ci has.
#
# Usage: tests/release_notes.sh  (runs on the host)

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly SCRIPT="${REPO_DIR}/scripts/release_notes.sh"
readonly REGEXP='^https://github.com/docker/github-builder/.github/.*$'
WORK=""
FAILED=0

# shellcheck source=image/lib/log.sh
source "${REPO_DIR}/image/lib/log.sh"

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
# Remove the work folder.
# Globals:
#   WORK
#######################################
cleanup() {
  if [[ -n "${WORK}" ]]; then
    rm -rf "${WORK}"
  fi
}

#######################################
# Put a fake docker on PATH: `docker run --rm <image> print-versions`
# prints one tool for ci and two for dev.
# Globals:
#   WORK, PATH
#######################################
fake_docker() {
  mkdir -p "${WORK}/bin"
  cat >"${WORK}/bin/docker" <<'EOF'
#!/bin/bash
case "$3" in
  */ci@*) echo "go=1.0.0" ;;
  *) printf '%s\n' "go=1.0.0" "aqua:sharkdp/fd=2.0.0" ;;
esac
EOF
  chmod +x "${WORK}/bin/docker"
  PATH="${WORK}/bin:${PATH}"
}

#######################################
# Print the notes for a fixed release, with the given provenance commands.
# Arguments:
#   PROVENANCE_VERIFY's value.
# Outputs:
#   The notes to STDOUT.
#######################################
notes() {
  (cd "${WORK}" && REGISTRY=ghcr.io/o/toolchain VERSION=1.2.3 \
    CI_DIGEST=sha256:c DEV_DIGEST=sha256:d IDENTITY=https://id \
    PROVENANCE_VERIFY="$1" "${SCRIPT}")
}

#######################################
# Print the lines of the sh block after the provenance paragraph.
# Arguments:
#   The notes.
# Outputs:
#   The block's lines to STDOUT.
#######################################
provenance_block() {
  awk '/provenance is also signed/ { found = 1 }
    found && /^```sh$/ { inside = 1; next }
    inside && /^```$/ { exit }
    inside { print }' <<<"$1"
}

#######################################
# Run commands with cosign replaced by a function that prints its regexp
# argument, under bash with failglob (an unmatched glob is an error).
# Arguments:
#   The commands.
# Outputs:
#   One regexp per command to STDOUT.
#######################################
run_commands() {
  (cd "${WORK}" && bash -O failglob -c '
    cosign() {
      while [[ $# -gt 0 ]]; do
        if [[ $1 == --certificate-identity-regexp ]]; then echo "$2"; fi
        shift
      done
    }
    '"$1")
}

#######################################
# Check the builder's commands: runnable as printed, regexp intact, no
# blank lines; an already quoted regexp is left alone.
# Globals:
#   REGEXP
#######################################
test_provenance() {
  local command="cosign verify --certificate-identity-regexp ${REGEXP} img"
  local raw block
  raw="$(printf '%s\n\n%s\n' "${command}@sha256:a" "${command}@sha256:b")"
  block="$(provenance_block "$(notes "${raw}")")"
  check "the builder's commands keep no blank lines" \
    test "$(grep -c '^$' <<<"${block}")" = 0
  check "the builder's commands run without globbing their regexp" \
    test "$(run_commands "${block}")" = "${REGEXP}"$'\n'"${REGEXP}"
  command="cosign verify --certificate-identity-regexp '${REGEXP}' img"
  block="$(provenance_block "$(notes "${command}")")"
  check "an already quoted regexp stays as it is" \
    test "$(run_commands "${block}")" = "${REGEXP}"
  check "no provenance section without the builder's commands" \
    test "$(notes "" | grep -c 'provenance is also signed')" = 0
}

#######################################
# Check the toolchain table: dev's tools, ci's marked, aqua: dropped.
#######################################
test_toolchain() {
  local out
  out="$(notes "")"
  # shellcheck disable=SC2016 # the backticks are literal Markdown
  check "a tool in both images is marked ci, dev" \
    grep -qxF '| `go` | 1.0.0 | ci, dev |' <<<"${out}"
  # shellcheck disable=SC2016
  check "a dev-only tool is marked dev, without its aqua: prefix" \
    grep -qxF '| `sharkdp/fd` | 2.0.0 | dev |' <<<"${out}"
}

main() {
  WORK="$(mktemp -d)"
  trap cleanup EXIT
  fake_docker
  test_provenance
  test_toolchain
  if [[ "${FAILED}" -ne 0 ]]; then
    log::fatal "release notes tests failed"
  fi
  log::ok "release notes tests passed"
}

main "$@"
