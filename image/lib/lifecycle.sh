# shellcheck shell=bash
#
# Dev container lifecycle state: which stage a container is in, and whether
# it's ready. Installed in the images at /usr/local/lib/toolchain/lifecycle.sh.
#
#   source /usr/local/lib/toolchain/lifecycle.sh
#   install_dependencies() { lifecycle::once dependencies npm ci; }
#   lifecycle::stage post-create install_dependencies
#
# State is a directory of marker files inside the container (not in the
# workspace), so a rebuild starts from nothing, like the container itself:
#
#   <stage>.started  <stage>.done  <stage>.failed  <stage>.log
#   <marker>.done    (lifecycle::once steps)
#   ready
#
# Each marker holds the time it was written (and .failed the exit status).
# `dev-status`, `dev-wait` and `dev-reset` read and clear them.
#
# Changes no shell options; sourcing it twice is harmless. Needs bash 4.2+.
#
# Environment:
#   TOOLCHAIN_STATE_DIR  the state directory (default:
#                        ${XDG_STATE_HOME:-~/.local/state}/toolchain/lifecycle)

[[ -n "${_TOOLCHAIN_LIFECYCLE_LOADED:-}" ]] && return 0

# shellcheck source=image/lib/log.sh
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
  source "${BASH_SOURCE[0]%/*}/log.sh" || return 1
else
  source "./log.sh" || return 1
fi

readonly _TOOLCHAIN_LIFECYCLE_LOADED=1
# Terminal escape sequences (colors, cursor movement), as a sed regex.
readonly _LIFECYCLE_ESCAPES=$'\e\\[[0-9;?]*[A-Za-z]'

#######################################
# Set REPLY to the state directory.
# Globals:
#   TOOLCHAIN_STATE_DIR, XDG_STATE_HOME, HOME
#   REPLY (set)
#######################################
lifecycle::dir() {
  local state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
  REPLY="${TOOLCHAIN_STATE_DIR:-${state_home}/toolchain/lifecycle}"
}

#######################################
# Write a marker file holding the current time and any extra words.
# Arguments:
#   Marker file name, then optional extra words.
#######################################
lifecycle::_mark() {
  local name="$1"
  shift
  local ts
  lifecycle::dir
  mkdir -p "${REPLY}"
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '%s\n' "${ts}${*:+ $*}" >"${REPLY}/${name}"
}

#######################################
# Set REPLY to "ignored" when errexit is being ignored here, because the
# caller was called from a condition (if, while, ||, !): bash then ignores
# errexit in everything it runs, subshells included, so a failing step
# wouldn't stop. Call it as a plain statement; from a condition, it would
# always answer "ignored".
# Globals:
#   REPLY (set)
#######################################
lifecycle::_errexit_probe() {
  REPLY="$(
    (
      set -e
      false
      echo ignored
    )
    true
  )"
}

#######################################
# Set REPLY to the prefix for a stage's progress lines: nothing when the
# log tag already names the stage (a post-create.sh running post-create),
# else "<stage>: ".
# Globals:
#   TOOLCHAIN_LOG_TAG
#   REPLY (set)
# Arguments:
#   Stage name.
#######################################
lifecycle::_prefix() {
  local tag="${TOOLCHAIN_LOG_TAG:-${0##*/}}"
  tag="${tag%.sh}"
  if [[ "${tag}" == "$1" ]]; then
    REPLY=""
  else
    REPLY="$1: "
  fi
}

#######################################
# Run one lifecycle stage and record it: <stage>.started, then <stage>.done
# or <stage>.failed (with the exit status), and the output in <stage>.log
# (also shown on STDERR, with colors; the log file has them removed).
# Starting a stage clears `ready` and the stage's previous result. Progress
# lines name the stage unless the log tag (the script's name) already does.
# The command runs in a subshell with errexit on, so a failing step stops
# it. Call it as a plain command, not from a condition (if, ||, !): bash
# would ignore errexit in the step, so it's refused.
# Arguments:
#   Stage name (post-create, post-start, ...), then a command and its
#   arguments (usually a function of the calling script).
# Outputs:
#   The command's output and progress lines to STDERR.
# Returns:
#   The command's exit status; 2 when called from a condition.
#######################################
lifecycle::stage() {
  local stage="$1"
  shift
  local dir status_file started prefix
  local -i status=0 seconds
  lifecycle::_errexit_probe
  if [[ "${REPLY}" == ignored ]]; then
    log::error "lifecycle::stage ${stage}: called from a condition (if," \
      "||, !), where bash ignores errexit; call it as a plain command"
    return 2
  fi
  lifecycle::_prefix "${stage}"
  prefix="${REPLY}"
  lifecycle::dir
  dir="${REPLY}"
  mkdir -p "${dir}"
  rm -f "${dir}/ready" "${dir}/${stage}.done" "${dir}/${stage}.failed"
  lifecycle::_mark "${stage}.started"
  : >"${dir}/${stage}.log"
  status_file="${dir}/.${stage}.status"
  started="${SECONDS}"
  log::info "${prefix}started"
  (
    set +e
    (
      set -euo pipefail
      "$@"
    )
    echo "$?" >"${status_file}"
  ) 2>&1 | tee -a "${dir}/${stage}.log" >&2
  # Colors stay on the terminal; the log file is for reading with any tool.
  sed -i "s/${_LIFECYCLE_ESCAPES}//g" "${dir}/${stage}.log"
  status="$(<"${status_file}")"
  rm -f "${status_file}"
  seconds=$((SECONDS - started))
  if ((status == 0)); then
    lifecycle::_mark "${stage}.done" "${seconds}s"
    log::ok "${prefix}done in ${seconds}s"
  else
    lifecycle::_mark "${stage}.failed" "exit=${status}"
    log::error "${prefix}failed (exit ${status}); log: ${dir}/${stage}.log"
  fi
  return "${status}"
}

#######################################
# Run a step once per container: skipped when its marker exists, marked
# when it succeeds. For expensive, idempotent work such as installing
# dependencies; `dev-reset <marker>` makes it run again.
# Arguments:
#   Marker name, then a command and its arguments.
# Outputs:
#   A line to STDERR when skipped.
# Returns:
#   The command's exit status, or 0 when skipped; 2 when called from a
#   condition (see lifecycle::stage).
#######################################
lifecycle::once() {
  local marker="$1"
  shift
  local -i status
  lifecycle::_errexit_probe
  if [[ "${REPLY}" == ignored ]]; then
    log::error "lifecycle::once ${marker}: called from a condition (if," \
      "||, !), where bash ignores errexit; call it as a plain command"
    return 2
  fi
  lifecycle::dir
  if [[ -f "${REPLY}/${marker}.done" ]]; then
    log::info "${marker}: already done in this container; skipped"
    return 0
  fi
  # Not `"$@" || return`: that's a condition, and would ignore errexit.
  "$@"
  status=$?
  if ((status != 0)); then
    return "${status}"
  fi
  lifecycle::_mark "${marker}.done"
}

#######################################
# Mark the container ready for use.
# Outputs:
#   A line to STDERR.
#######################################
lifecycle::ready() {
  lifecycle::_mark ready
  log::ok "ready"
}

#######################################
# Set REPLY to the container's overall state:
#   created         nothing recorded yet
#   bootstrapping   a stage has started and not finished
#   partial         stages finished, but not marked ready
#   failed          a stage failed
#   ready           marked ready
# Globals:
#   REPLY (set)
#######################################
lifecycle::state() {
  local dir started
  lifecycle::dir
  dir="${REPLY}"
  if [[ -f "${dir}/ready" ]]; then
    REPLY="ready"
    return 0
  fi
  if compgen -G "${dir}/*.failed" >/dev/null; then
    REPLY="failed"
    return 0
  fi
  for started in "${dir}"/*.started; do
    [[ -f "${started}" ]] || continue
    if [[ ! -f "${started%.started}.done" ]]; then
      REPLY="bootstrapping"
      return 0
    fi
  done
  if compgen -G "${dir}/*.done" >/dev/null; then
    REPLY="partial"
  else
    REPLY="created"
  fi
}
