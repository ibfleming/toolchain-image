# shellcheck shell=bash
#
# Readiness checks with actionable messages, for dev container lifecycle
# scripts. Installed in the images at /usr/local/lib/toolchain/validate.sh.
#
#   source /usr/local/lib/toolchain/validate.sh
#   validate::tool kubectl
#   validate::mount ~/.kube "mount ~/.kube in devcontainer.json"
#   validate::env DATABASE_URL "set it in .devcontainer/.env"
#   validate::report || exit 1
#
# Each check logs OK, or ERROR with its hint, and returns 0 either way, so
# a script under `set -e` runs them all; validate::report then decides.
# validate::sign_ins reports the usual sign-ins (git, SSH agent, GitHub CLI,
# Claude Code) as warnings, since a missing sign-in is something to do, not
# a broken container.
#
# Changes no shell options; sourcing it twice is harmless. Needs bash 4.2+.

[[ -n "${_TOOLCHAIN_VALIDATE_LOADED:-}" ]] && return 0

# shellcheck source=image/lib/log.sh
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
  source "${BASH_SOURCE[0]%/*}/log.sh" || return 1
else
  source "./log.sh" || return 1
fi

readonly _TOOLCHAIN_VALIDATE_LOADED=1
declare -gi _VALIDATE_FAILED=0
declare -gi _VALIDATE_PASSED=0

#######################################
# Run a check and record the result.
# Globals:
#   _VALIDATE_FAILED, _VALIDATE_PASSED
# Arguments:
#   What is checked, the hint when it fails, then a command and its
#   arguments; the check passes when the command succeeds.
# Outputs:
#   An OK or ERROR line to STDERR.
#######################################
validate::check() {
  local what="$1"
  local hint="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    _VALIDATE_PASSED+=1
    log::ok "${what}"
    return 0
  fi
  _VALIDATE_FAILED+=1
  log::error "${what}: ${hint}"
}

#######################################
# Check that a command is on PATH.
# Arguments:
#   Command name, then an optional hint.
#######################################
validate::tool() {
  local hint="${2:-not on PATH; add it to the image or a derived image}"
  validate::check "tool $1" "${hint}" command -v "$1"
}

#######################################
# Check that a path exists (a mount, a file or a directory).
# Arguments:
#   Path, then an optional hint.
#######################################
validate::mount() {
  local hint="${2:-missing; check the mounts in devcontainer.json}"
  validate::check "path $1" "${hint}" test -e "$1"
}

#######################################
# Check that an environment variable is set and not empty.
# Arguments:
#   Variable name, then an optional hint.
#######################################
validate::env() {
  local hint="${2:-not set; set it in devcontainer.json (containerEnv)}"
  validate::check "env $1" "${hint}" test -n "${!1:-}"
}

#######################################
# Summarize the checks so far and reset the counts.
# Globals:
#   _VALIDATE_FAILED, _VALIDATE_PASSED
# Outputs:
#   A summary line to STDERR.
# Returns:
#   0 if every check passed, 1 if any failed.
#######################################
validate::report() {
  local -i failed="${_VALIDATE_FAILED}"
  local -i total=$((_VALIDATE_FAILED + _VALIDATE_PASSED))
  _VALIDATE_FAILED=0
  _VALIDATE_PASSED=0
  if ((failed > 0)); then
    log::error "${failed} of ${total} checks failed"
    return 1
  fi
  log::ok "all ${total} checks passed"
}

#######################################
# Report the usual sign-ins as OK or WARN (never counted as failures).
# Globals:
#   SSH_AUTH_SOCK, CLAUDE_CONFIG_DIR, HOME
# Outputs:
#   One line per sign-in to STDERR.
#######################################
validate::sign_ins() {
  local email claude_creds
  claude_creds="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json"
  email="$(git config --get user.email 2>/dev/null || true)"
  if [[ -n "${email}" ]]; then
    log::ok "git: ${email}"
  else
    log::warn "git: no identity; set user.name and user.email in your" \
      "host's ~/.gitconfig (VS Code copies it in)"
  fi
  if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l >/dev/null 2>&1; then
    log::ok "ssh: agent with keys"
  else
    log::warn "ssh: no agent keys; start an SSH agent on the host and add" \
      "your key (VS Code forwards it)"
  fi
  if ! command -v gh >/dev/null 2>&1; then
    :
  elif gh auth status >/dev/null 2>&1; then
    log::ok "gh: signed in"
  else
    log::warn "gh: not signed in; run gh auth login"
  fi
  if [[ -s "${claude_creds}" || -n "${ANTHROPIC_API_KEY:-}" ]]; then
    log::ok "claude: signed in"
  else
    log::warn "claude: not signed in; sign in from the Claude Code panel"
  fi
}
