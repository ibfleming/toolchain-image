#!/bin/bash
#
# Render the README screenshots of the dev image's `welcome` views into
# docs/assets/, from the local dev image (`make build` first).
#
# Everything machine-specific comes from fixtures (a sample repository, git
# identity, SSH agent, kube context, Claude Code and GitHub CLI sign-in), so
# the pictures are the same on every machine and show nobody's real setup.
# The version shown is the next minor after the latest release, with that
# release's tools as "previous" (needs gh) when available.
#
# Usage: FONT=<font.ttf> [FONT_FAMILY='CaskaydiaCove NFM'] screenshots.sh
# FONT must be a Nerd Font *Mono* (single-width icons), e.g. CaskaydiaCove
# Nerd Font Mono.

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly IMAGE="${DEV_IMG:-toolchain/dev:local}"
readonly RESVG="@resvg/resvg-js@2.6.2"
readonly PROMPT_MARK=$'\e[38;2;198;120;221m❯\e[0m'
# Runs in the container (zsh, as vscode): a fake SSH agent, then each view.
# shellcheck disable=SC2016 # expanded by the container's zsh
readonly CAPTURE_ZSH='
  python3 -c "import socket
socket.socket(socket.AF_UNIX).bind(\"/tmp/agent.sock\")"
  welcome >/out/welcome.ansi
  for view in tools keys; do
    { print -r -- "${PROMPT_MARK} welcome ${view}"; welcome "${view}"; } \
      >"/out/welcome-${view}.ansi"
  done'
# Runs in the container (bash): install resvg, render each view.
# shellcheck disable=SC2016 # expanded by the container's bash
readonly RENDER_BASH='
  npm install --silent --no-save --no-package-lock "$1" >/dev/null
  for f in welcome welcome-tools welcome-keys; do
    node render.js "${f}.ansi" "${f}.png" /font.ttf "$2"
  done'

# shellcheck source=image/lib/log.sh
source "${REPO_DIR}/image/lib/log.sh"
# shellcheck source=scripts/lib/host_path.sh
source "${REPO_DIR}/scripts/lib/host_path.sh"

WORK=""

#######################################
# Write the build metadata the views read: the next minor version after
# the latest release, compared against that release.
# Globals:
#   REPO_DIR
#   WORK
# Outputs:
#   Writes WORK/release and WORK/previous.
#######################################
write_metadata() {
  local previous prev_version revision today major minor
  previous="$("${REPO_DIR}/scripts/previous_tools.sh" 2>/dev/null || true)"
  prev_version="$(sed -n 's/^PREVIOUS_VERSION=//p' <<<"${previous}")"
  IFS=. read -r major minor _ <<<"${prev_version:-0.0.0}"
  revision="$(git -C "${REPO_DIR}" rev-parse HEAD)"
  printf -v today '%(%F)T' -1
  printf '%s\n' \
    "TOOLCHAIN_VERSION=${major}.$((minor + 1)).0" \
    "TOOLCHAIN_REVISION=${revision}" \
    "TOOLCHAIN_CREATED=${today}" \
    "TOOLCHAIN_PREVIOUS=${prev_version}" >"${WORK}/release"
  sed -n 's/^PREVIOUS_TOOLS=//p' <<<"${previous}" \
    | tr ' ' '\n' \
    | sed '/^$/d' >"${WORK}/previous"
}

#######################################
# Write the fixtures for the project and status rows.
# Globals:
#   WORK
# Outputs:
#   Writes the fixture files under WORK.
#######################################
write_fixtures() {
  mkdir -p "${WORK}/sample/.git"
  echo 'ref: refs/heads/main' >"${WORK}/sample/.git/HEAD"
  printf '[user]\n  name = Dev\n  email = dev@example.com\n' \
    >"${WORK}/gitconfig"
  printf 'apiVersion: v1\nkind: Config\ncurrent-context: dev-cluster\n' \
    >"${WORK}/kubeconfig"
  echo '{}' >"${WORK}/credentials.json"
  printf 'github.com:\n  user: dev\n' >"${WORK}/gh-hosts.yml"
}

#######################################
# Capture the welcome views as ANSI text, in the dev image, with the
# fixtures mounted where the views look for them.
# Globals:
#   IMAGE, PROMPT_MARK, CAPTURE_ZSH, WORK
# Outputs:
#   Writes WORK/out/welcome*.ansi.
#######################################
capture_views() {
  local home="/home/vscode"
  local work
  work="$(host_path::of "${WORK}")"
  docker run --rm -t -u vscode -e COLUMNS=100 \
    -e SSH_AUTH_SOCK=/tmp/agent.sock -e PROMPT_MARK="${PROMPT_MARK}" \
    -v "${work}/release:/etc/toolchain/release:ro" \
    -v "${work}/previous:/etc/toolchain/previous:ro" \
    -v "${work}/sample:/workspaces/my-service:ro" \
    -w /workspaces/my-service \
    -v "${work}/gitconfig:${home}/.gitconfig:ro" \
    -v "${work}/kubeconfig:${home}/.kube/config:ro" \
    -v "${work}/credentials.json:${home}/.claude/.credentials.json:ro" \
    -v "${work}/gh-hosts.yml:${home}/.config/gh/hosts.yml:ro" \
    -v "${work}/out:/out" \
    "${IMAGE}" zsh -i -c "${CAPTURE_ZSH}" >/dev/null
}

#######################################
# Render the captured views to PNG with the dev image's Node and a pinned
# resvg, then copy them into docs/assets/.
# Globals:
#   IMAGE, RESVG, RENDER_BASH, REPO_DIR, WORK
# Arguments:
#   Font file, font family.
# Outputs:
#   The renderer's summary lines to STDOUT; writes docs/assets/welcome*.png.
#######################################
render_pngs() {
  local font="$1"
  local family="$2"
  local font_path work
  font_path="$(host_path::of "$(realpath "${font}")")"
  work="$(host_path::of "${WORK}")"
  cp "${REPO_DIR}/scripts/screenshots/render.js" "${WORK}/out/"
  docker run --rm -u vscode -e NPM_CONFIG_UPDATE_NOTIFIER=false \
    -e NPM_CONFIG_FUND=false \
    -v "${work}/out:/out" -v "${font_path}:/font.ttf:ro" -w /out \
    "${IMAGE}" bash -c "${RENDER_BASH}" _ "${RESVG}" "${family}"
  cp "${WORK}"/out/welcome*.png "${REPO_DIR}/docs/assets/"
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
  if [[ -z "${FONT:-}" ]]; then
    log::fatal "set FONT to a Nerd Font Mono .ttf file"
  fi
  # In the repository, not /tmp: inside a dev container, the host's Docker
  # engine can only mount the workspace (see scripts/lib/host_path.sh).
  mkdir -p "${REPO_DIR}/.tmp"
  WORK="$(mktemp -d "${REPO_DIR}/.tmp/screenshots.XXXXXX")"
  trap cleanup EXIT
  mkdir -p "${WORK}/out"
  chmod 0777 "${WORK}/out" # written by the image's vscode user
  write_metadata
  write_fixtures
  capture_views
  render_pngs "${FONT}" "${FONT_FAMILY:-CaskaydiaCove NFM}"
  log::ok "screenshots written to docs/assets/"
}

main "$@"
