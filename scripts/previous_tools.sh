#!/bin/bash
#
# Print the previous release as bake variables, for the "what changed" marks
# in the dev image's `welcome` (baked into /etc/toolchain/previous):
#   PREVIOUS_VERSION=X.Y.Z
#   PREVIOUS_TOOLS=tool=version tool=version ...
#
# The previous release is the highest vX.Y.Z tag below version $1 (default:
# the highest tag). Its toolchain comes from that GitHub Release's notes
# (the "## Toolchain" table), so no image is pulled. Prints nothing when
# there is no previous release or its notes can't be read; the image then
# shows no marks. Needs gh with access to the repository (GH_TOKEN in CI).
#
# Usage: previous_tools.sh [current version]
# STDOUT is the data ($GITHUB_ENV); messages go to STDERR.

set -euo pipefail

readonly SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
# A "| `tool` | version | where |" row of the release notes' toolchain table.
# shellcheck disable=SC2016 # the backticks are literal Markdown
readonly TOOL_ROW_SED='s/^\| `([^`]+)` \| ([^ |]+) \|.*/\1=\2/'

# shellcheck source=image/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../image/lib/log.sh"

#######################################
# Print the newest vX.Y.Z tag below a version, or the newest tag at all.
# Arguments:
#   Current version X.Y.Z (optional).
# Outputs:
#   The tag to STDOUT, or nothing.
#######################################
previous_tag() {
  local current="${1:-}"
  local tag lowest
  while read -r tag; do
    [[ "${tag}" =~ ${SEMVER_RE} ]] || continue
    if [[ -z "${current}" ]]; then
      echo "${tag}"
      return 0
    fi
    if [[ "${tag#v}" == "${current}" ]]; then
      continue
    fi
    lowest="$(printf '%s\n' "${tag#v}" "${current}" | sort -V | head -n1)"
    if [[ "${lowest}" == "${tag#v}" ]]; then
      echo "${tag}"
      return 0
    fi
  done < <(git tag --list 'v*.*.*' --sort=-v:refname)
}

#######################################
# Print a release's toolchain as space-separated tool=version pairs.
# Globals:
#   TOOL_ROW_SED
# Arguments:
#   The release's tag.
# Outputs:
#   The pairs to STDOUT; nothing if the notes can't be read.
#######################################
release_tools() {
  local tag="$1"
  local notes
  if ! notes="$(gh release view "${tag}" --json body --jq .body \
    2>/dev/null)"; then
    log::warn "can't read the notes of ${tag}; no what-changed marks"
    return 0
  fi
  # shellcheck disable=SC2016 # the backtick is literal Markdown
  awk '/^## Toolchain/ { on = 1; next } /^## / { on = 0 } on && /^\| `/' \
    <<<"${notes//$'\r'/}" \
    | sed -E "${TOOL_ROW_SED}" \
    | paste -sd ' ' -
}

main() {
  local previous tools
  previous="$(previous_tag "${1:-}")"
  if [[ -z "${previous}" ]]; then
    log::info "no previous release"
    return 0
  fi
  tools="$(release_tools "${previous}")"
  if [[ -z "${tools}" ]]; then
    return 0
  fi
  log::info "previous release: ${previous}"
  printf 'PREVIOUS_VERSION=%s\nPREVIOUS_TOOLS=%s\n' "${previous#v}" "${tools}"
}

main "$@"
