#!/bin/bash
#
# Symlink every executable from the installed mise tools into /usr/local/bin.
# Installed in the images as /usr/local/sbin/link-tools.
#
# The images use no mise shims at runtime: shims re-resolve versions from
# whatever mise.toml or .tool-versions a job's workspace contains, which
# brings back runtime resolution and drift. Plain symlinks keep the
# manifest's versions fixed.

set -euo pipefail

readonly DEST_DIR="/usr/local/bin"

# shellcheck source=image/lib/log.sh
source "${TOOLCHAIN_LIB_DIR:-/usr/local/lib/toolchain}/log.sh"

# Tool name -> the bin directory that provides it (to catch duplicates).
declare -A OWNER=()
declare -i LINKED=0

#######################################
# Link one executable into DEST_DIR, unless an earlier run already did.
# Globals:
#   DEST_DIR
#   LINKED (incremented)
# Arguments:
#   Path of the executable.
# Outputs:
#   Logs a refusal to STDERR.
# Returns:
#   0 if linked or already linked; 1 if another file has the name.
#######################################
link_exe() {
  local exe="$1"
  local name="${exe##*/}"
  local link="${DEST_DIR}/${name}"
  local target
  # Link the fully resolved target: tools like npm are themselves relative
  # symlinks and find their modules from the path they're invoked through.
  target="$(readlink -f "${exe}")"
  if [[ -e "${link}" || -L "${link}" ]]; then
    # Already linked by an earlier run (ci tools, seen again in dev).
    if [[ "$(readlink "${link}")" == "${target}" ]]; then
      return 0
    fi
    log::error "${link} already exists (refusing to shadow)"
    return 1
  fi
  ln -s "${target}" "${link}"
  LINKED+=1
}

#######################################
# Link every executable in one tool's bin directory.
# Globals:
#   OWNER (updated)
# Arguments:
#   Bin directory.
# Outputs:
#   Logs a name conflict to STDERR.
# Returns:
#   0 on success; 1 if two tools provide the same name, or linking fails.
#######################################
link_dir() {
  local dir="$1"
  local exe name
  [[ -d "${dir}" ]] || return 0
  for exe in "${dir}"/*; do
    [[ -f "${exe}" && -x "${exe}" ]] || continue
    name="${exe##*/}"
    if [[ -n "${OWNER[${name}]:-}" ]]; then
      log::error "'${name}' provided by both ${OWNER[${name}]} and ${dir}"
      return 1
    fi
    OWNER[${name}]="${dir}"
    link_exe "${exe}" || return 1
  done
}

main() {
  local dir paths
  # Captured first: a failure inside the process substitution of a loop
  # would go unnoticed and link nothing.
  paths="$(cd / && mise bin-paths)" || log::fatal "mise bin-paths failed"
  while IFS= read -r dir; do
    link_dir "${dir}" || exit 1
  done <<<"${paths}"
  log::info "linked ${LINKED} new executables into ${DEST_DIR}" \
    "(${#OWNER[@]} seen)"
}

main "$@"
