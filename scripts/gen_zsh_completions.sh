#!/bin/bash
#
# Generate zsh completion functions for the pinned tools at image build
# time, so shells don't pay `source <(tool completion zsh)` on every start.
# Installed in the dev image as /usr/local/sbin/gen-zsh-completions.
#
# Tools whose completions ship with zsh (git, go, cmake, make, ...) or are
# wired up elsewhere (fzf, zoxide, tofu via bashcompinit) are not listed.
#
# Usage: gen-zsh-completions [dir]
#   dir defaults to /usr/local/share/zsh/site-functions.

set -euo pipefail

readonly DEFAULT_DEST="/usr/local/share/zsh/site-functions"

# shellcheck source=scripts/lib/log.sh
source "${TOOLCHAIN_LIB_DIR:-/usr/local/lib/toolchain}/log.sh"

#######################################
# Write one tool's completion function and check it isn't empty.
# Arguments:
#   Destination directory.
#   Completion name (the file is _<name>).
#   The command that prints the completion, and its arguments.
# Outputs:
#   Writes <dir>/_<name>; logs an empty result to STDERR.
# Returns:
#   0 on success; 1 if the command failed or printed nothing.
#######################################
gen() {
  local dest="$1"
  local name="$2"
  shift 2
  local file="${dest}/_${name}"
  "$@" >"${file}" || return 1
  if [[ ! -s "${file}" ]]; then
    log::error "empty completion output for ${name}"
    return 1
  fi
}

main() {
  local dest="${1:-${DEFAULT_DEST}}"
  local -a files
  mkdir -p "${dest}"
  gen "${dest}" kubectl kubectl completion zsh
  gen "${dest}" helm helm completion zsh
  gen "${dest}" k9s k9s completion zsh
  gen "${dest}" uv uv generate-shell-completion zsh
  gen "${dest}" uvx uvx --generate-shell-completion zsh
  gen "${dest}" ruff ruff generate-shell-completion zsh
  gen "${dest}" starship starship completions zsh
  gen "${dest}" rg rg --generate complete-zsh
  gen "${dest}" fd fd --gen-completions zsh
  gen "${dest}" bat bat --completion zsh
  gen "${dest}" delta delta --generate-completion zsh
  gen "${dest}" gh gh completion --shell zsh
  files=("${dest}"/_*)
  log::info "wrote ${#files[@]} completion files to ${dest}"
}

main "$@"
