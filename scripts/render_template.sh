#!/bin/bash
#
# Render the consumer repository template (template/) with a dev image
# reference filled in, into a folder or a .tar.gz. The repository keeps a
# placeholder; each release attaches the rendered template, ready to unpack
# into a repository, and the template test renders it with the local build.
#
# Usage: render_template.sh IMAGE OUTPUT
#   IMAGE   the dev image, e.g. ghcr.io/acme/toolchain/dev:1.2.3@sha256:...
#   OUTPUT  a folder to create, or a file name ending in .tar.gz
#
# Fails if the placeholder isn't found exactly once, so a changed template
# can't ship with the placeholder still in it.

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly TEMPLATE_DIR="${REPO_DIR}/template"
readonly CONFIG=".devcontainer/devcontainer.json"
readonly PLACEHOLDER='ghcr.io/<owner>/toolchain/dev:<version>@sha256:<digest>'
# Scratch folder for a .tar.gz output (removed on exit).
WORK=""

# shellcheck source=image/lib/log.sh
source "${REPO_DIR}/image/lib/log.sh"

#######################################
# Copy the template into a folder and fill in the image reference.
# Globals:
#   TEMPLATE_DIR, CONFIG, PLACEHOLDER
# Arguments:
#   Image reference, destination folder (must not exist yet).
#######################################
render_into() {
  local image="$1"
  local dest="$2"
  local count
  [[ ! -e "${dest}" ]] || log::fatal "${dest} already exists"
  cp -R "${TEMPLATE_DIR}" "${dest}"
  count="$(grep -cF "\"${PLACEHOLDER}\"" "${dest}/${CONFIG}" || true)"
  [[ "${count}" == 1 ]] \
    || log::fatal "expected the image placeholder once in ${CONFIG}," \
      "found it ${count} times"
  # Neither string can contain "|": an image reference has no such character.
  sed -i "s|\"${PLACEHOLDER}\"|\"${image}\"|" "${dest}/${CONFIG}"
}

main() {
  local image="${1:-}"
  local output="${2:-}"
  if [[ -z "${image}" || -z "${output}" || "${image}" == *[\|\"]* ]]; then
    log::fatal "usage: render_template.sh IMAGE OUTPUT (folder or .tar.gz)"
  fi
  if [[ "${output}" != *.tar.gz ]]; then
    render_into "${image}" "${output}"
    log::ok "template rendered into ${output} (image ${image})"
    return 0
  fi
  WORK="$(mktemp -d)"
  trap 'rm -rf -- "${WORK}"' EXIT
  render_into "${image}" "${WORK}/template"
  tar -C "${WORK}/template" --owner=0 --group=0 --numeric-owner \
    -czf "${output}" .
  log::ok "template rendered into ${output} (image ${image})"
}

main "$@"
