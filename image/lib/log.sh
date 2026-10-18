# shellcheck shell=bash
#
# Leveled, colored, timestamped logging for the toolchain's Bash scripts,
# and for yours: installed in the images at /usr/local/lib/toolchain/log.sh.
#
#   source /usr/local/lib/toolchain/log.sh
#   log::info "linked 21 executables"
#   # 2026-10-12T13:09:31-0700 INFO  link-tools: linked 21 executables
#
# Every level writes to STDERR, so STDOUT stays free for a script's data.
# Uses only builtins (no subshells), so it is cheap to call often.
# Changes no shell options; sourcing it twice is harmless. Needs bash 4.2+.
#
# Environment:
#   TOOLCHAIN_LOG_LEVEL  debug | info (default) | warn | error
#   TOOLCHAIN_LOG_COLOR  auto (default) | always | never
#   NO_COLOR             disables color in auto mode (https://no-color.org)
#   TOOLCHAIN_LOG_TAG    the name in each line (default: the script's name)
#   GITHUB_ACTIONS       when "true": colors on, and warnings and errors
#                        also become annotations on the workflow run
#
# Log text can't run CI commands, in any environment (CI output also comes
# from scripts in containers, which don't see GITHUB_ACTIONS): a message's
# line breaks indent its continuation lines, so no line starts with "::"
# (GitHub Actions), and "##vso[" (Azure DevOps) and "##[" are broken up
# ("# #vso[") wherever they appear.

[[ -n "${_TOOLCHAIN_LOG_LOADED:-}" ]] && return 0

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && \
  BASH_VERSINFO[1] < 2))); then
  echo "log.sh: needs bash 4.2 or newer (this is ${BASH_VERSION})" >&2
  return 1
fi

# shellcheck source=image/lib/palette.sh
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
  source "${BASH_SOURCE[0]%/*}/palette.sh" || return 1
else
  source "./palette.sh" || return 1
fi

readonly _TOOLCHAIN_LOG_LOADED=1
declare -grA _LOG_SEVERITY=(
  [DEBUG]=10 [INFO]=20 [OK]=20 [WARN]=30 [ERROR]=40 [FATAL]=50
)

#######################################
# Set REPLY to the SGR sequence for a palette color, or to nothing when
# color is off.
# Globals:
#   COLORTERM
#   REPLY (set)
# Arguments:
#   Color as #rrggbb.
#   Nearest xterm 256-color index.
#   Extra SGR attributes, e.g. "1;" for bold (optional).
#######################################
log::_sgr() {
  local hex="$1"
  local -i index="$2"
  local attrs="${3:-}"
  case "${COLORTERM:-}" in
    truecolor | 24bit)
      REPLY=$'\e['"${attrs}38;2;$((16#${hex:1:2}));$((16#${hex:3:2}))"
      REPLY+=";$((16#${hex:5:2}))m"
      ;;
    *) REPLY=$'\e['"${attrs}38;5;${index}m" ;;
  esac
}

#######################################
# Decide whether log lines are colored: TOOLCHAIN_LOG_COLOR wins, then
# NO_COLOR, then whether STDERR is a terminal or GitHub Actions.
# Globals:
#   TOOLCHAIN_LOG_COLOR
#   NO_COLOR
#   GITHUB_ACTIONS
# Returns:
#   0 if colors are on, 1 otherwise.
#######################################
log::_color_on() {
  case "${TOOLCHAIN_LOG_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ -t 2 || "${GITHUB_ACTIONS:-}" == "true" ]]
}

#######################################
# Precompute the colors, once, when the library is sourced.
# Globals:
#   PALETTE_* (read)
#   _LOG_COLOR, _LOG_DIM, _LOG_TAG, _LOG_RESET (set, read-only)
#######################################
log::_init() {
  declare -gA _LOG_COLOR=()
  local dim="" tag="" reset=""
  if log::_color_on; then
    log::_sgr "${PALETTE_DIM}" "${PALETTE_DIM_256}"
    dim="${REPLY}"
    _LOG_COLOR[DEBUG]="${REPLY}"
    log::_sgr "${PALETTE_BLUE}" "${PALETTE_BLUE_256}"
    _LOG_COLOR[INFO]="${REPLY}"
    log::_sgr "${PALETTE_GREEN}" "${PALETTE_GREEN_256}"
    _LOG_COLOR[OK]="${REPLY}"
    log::_sgr "${PALETTE_YELLOW}" "${PALETTE_YELLOW_256}"
    _LOG_COLOR[WARN]="${REPLY}"
    log::_sgr "${PALETTE_RED}" "${PALETTE_RED_256}"
    _LOG_COLOR[ERROR]="${REPLY}"
    log::_sgr "${PALETTE_RED}" "${PALETTE_RED_256}" "1;"
    _LOG_COLOR[FATAL]="${REPLY}"
    log::_sgr "${PALETTE_PURPLE}" "${PALETTE_PURPLE_256}"
    tag="${REPLY}"
    reset=$'\e[0m'
  fi
  readonly _LOG_COLOR
  readonly _LOG_DIM="${dim}" _LOG_TAG="${tag}" _LOG_RESET="${reset}"
}

#######################################
# Set REPLY to the lowest severity that is printed, from
# TOOLCHAIN_LOG_LEVEL (unknown values mean info).
# Globals:
#   TOOLCHAIN_LOG_LEVEL
#   REPLY (set)
#######################################
log::_threshold() {
  case "${TOOLCHAIN_LOG_LEVEL:-info}" in
    debug | DEBUG) REPLY=10 ;;
    warn | WARN | warning | WARNING) REPLY=30 ;;
    error | ERROR) REPLY=40 ;;
    *) REPLY=20 ;;
  esac
}

#######################################
# Escape a GitHub Actions workflow-command value: a message, or with
# "property", a property value such as an annotation title (which also
# escapes ":" and ",").
# Globals:
#   REPLY (set)
# Arguments:
#   The value, then optionally "property".
#######################################
log::_gha_escape() {
  local value="$1"
  value="${value//'%'/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  if [[ "${2:-}" == "property" ]]; then
    value="${value//:/%3A}"
    value="${value//,/%2C}"
  fi
  REPLY="${value}"
}

#######################################
# Set REPLY to text that can't run a CI command when printed: CR LF and lone
# CRs become line breaks, every continuation line is indented by two spaces
# (so none starts with "::"), and the "##vso[" and "##[" prefixes are broken
# up wherever they appear.
# Globals:
#   REPLY (set)
# Arguments:
#   The text.
#######################################
log::_safe_text() {
  local text="$1"
  text="${text//$'\r\n'/$'\n'}"
  text="${text//$'\r'/$'\n'}"
  text="${text//$'\n'/$'\n'  }"
  text="${text//'##vso['/'# #vso['}"
  REPLY="${text//'##['/'# #['}"
}

#######################################
# Write one log line to STDERR, if the level is enabled.
# Globals:
#   TOOLCHAIN_LOG_TAG
#   GITHUB_ACTIONS
#   _LOG_SEVERITY, _LOG_COLOR, _LOG_DIM, _LOG_TAG, _LOG_RESET
# Arguments:
#   Level: DEBUG, INFO, OK, WARN, ERROR or FATAL.
#   Message words (joined with spaces).
# Outputs:
#   The line to STDERR (made safe by log::_safe_text); for WARN and above in
#   GitHub Actions, also an annotation command.
#######################################
log::_emit() {
  local level="$1"
  shift
  local message="$*"
  local ts tag
  log::_threshold
  if ((_LOG_SEVERITY[${level}] < REPLY)); then
    return 0
  fi
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  tag="${TOOLCHAIN_LOG_TAG:-${0##*/}}"
  tag="${tag%.sh}"
  local safe_tag safe_message
  log::_safe_text "${tag}"
  safe_tag="${REPLY}"
  log::_safe_text "${message}"
  safe_message="${REPLY}"
  printf '%s%s%s %s%-5s%s %s%s:%s %s\n' \
    "${_LOG_DIM}" "${ts}" "${_LOG_RESET}" \
    "${_LOG_COLOR[${level}]:-}" "${level}" "${_LOG_RESET}" \
    "${_LOG_TAG}" "${safe_tag}" "${_LOG_RESET}" "${safe_message}" >&2
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]] \
    && ((_LOG_SEVERITY[${level}] >= 30)); then
    local kind="error" title
    [[ "${level}" == "WARN" ]] && kind="warning"
    log::_gha_escape "${tag}" property
    title="${REPLY}"
    log::_gha_escape "${message}"
    printf '::%s title=%s::%s\n' "${kind}" "${title}" "${REPLY}" >&2
  fi
}

#######################################
# Log at a level. log::ok is INFO-level success, labeled OK in green.
# log::fatal logs, then exits the script with status 1.
# Arguments:
#   Message words.
# Outputs:
#   One line to STDERR (see log::_emit).
#######################################
log::debug() { log::_emit DEBUG "$@"; }
log::info() { log::_emit INFO "$@"; }
log::ok() { log::_emit OK "$@"; }
log::warn() { log::_emit WARN "$@"; }
log::error() { log::_emit ERROR "$@"; }
log::fatal() {
  log::_emit FATAL "$@"
  exit 1
}

log::_init
