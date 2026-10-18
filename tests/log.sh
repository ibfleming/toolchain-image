#!/bin/bash
#
# Tests for the logging library (image/lib/log.sh): levels, STDERR only,
# line format, colors and their switches, GitHub Actions annotations,
# log::fatal, and sourcing twice. Each case runs in a fresh bash, because
# colors are decided when the library is sourced.
#
# Usage: tests/log.sh [lib dir]  (default: scripts/lib next to this repo's
# tests; the images' copy is /usr/local/lib/toolchain)

set -euo pipefail

# ISO 8601 with a UTC offset, e.g. 2026-10-12T13:09:31-0700.
readonly DATE_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}'
readonly TIME_RE='[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}'
readonly TS_RE="${DATE_RE}T${TIME_RE}"
readonly ESC=$'\e'
LIB_DIR=""
FAILED=0

#######################################
# Run a snippet in a clean bash that has sourced the library.
# Globals:
#   LIB_DIR
# Arguments:
#   Environment assignments (NAME=value), then "--", then the snippet.
# Outputs:
#   The snippet's STDOUT, then "--stderr--", then its STDERR.
#######################################
run_log() {
  local -a env_vars=()
  while [[ "$1" != "--" ]]; do
    env_vars+=("$1")
    shift
  done
  shift
  local out err
  err="$(mktemp)"
  out="$(env -i PATH="${PATH}" "${env_vars[@]}" bash -c \
    "set -euo pipefail; source '${LIB_DIR}/log.sh'; $1" 2>"${err}")" \
    || true
  printf '%s\n--stderr--\n%s\n' "${out}" "$(<"${err}")"
  rm -f "${err}"
}

#######################################
# Record one check.
# Globals:
#   FAILED
# Arguments:
#   Description.
#   Command and arguments; the check passes when it succeeds.
# Outputs:
#   "ok" or "FAIL" with the description, to STDOUT.
#######################################
check() {
  local description="$1"
  shift
  if "$@"; then
    printf 'ok   %s\n' "${description}"
  else
    printf 'FAIL %s\n' "${description}"
    FAILED=1
  fi
}

#######################################
# Succeed when a string matches an extended regular expression.
# Arguments:
#   String, regex.
#######################################
matches() {
  [[ "$1" =~ $2 ]]
}

#######################################
# Succeed when a string does not contain another.
# Arguments:
#   String, substring.
#######################################
lacks() {
  [[ "$1" != *"$2"* ]]
}

main() {
  LIB_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib" && pwd)}"
  local result

  result="$(run_log TOOLCHAIN_LOG_COLOR=never -- \
    'log::info "linked 21"; echo data')"
  check "STDOUT carries only the script's data" \
    matches "${result}" $'^data\n--stderr--\n'
  check "format: timestamp, level, tag, message" \
    matches "${result}" "${TS_RE} INFO  bash: linked 21"

  result="$(run_log TOOLCHAIN_LOG_COLOR=never TOOLCHAIN_LOG_TAG=demo.sh -- \
    'log::debug d; log::info i; log::ok o; log::warn w; log::error e')"
  check "default level info: debug hidden, the rest shown" \
    matches "${result}" \
    "INFO  demo: i.*OK    demo: o.*WARN  demo: w.*ERROR demo: e"
  check "debug hidden by default" lacks "${result}" "DEBUG"

  result="$(run_log TOOLCHAIN_LOG_COLOR=never TOOLCHAIN_LOG_LEVEL=debug -- \
    'log::debug d')"
  check "TOOLCHAIN_LOG_LEVEL=debug shows debug" \
    matches "${result}" "DEBUG bash: d"

  result="$(run_log TOOLCHAIN_LOG_COLOR=never TOOLCHAIN_LOG_LEVEL=warn -- \
    'log::info i; log::warn w')"
  check "TOOLCHAIN_LOG_LEVEL=warn hides info" lacks "${result}" "INFO"
  check "TOOLCHAIN_LOG_LEVEL=warn shows warn" \
    matches "${result}" "WARN  bash: w"

  result="$(run_log -- 'log::info i')"
  check "auto: no color when STDERR is not a terminal" \
    lacks "${result}" "${ESC}"

  result="$(run_log TOOLCHAIN_LOG_COLOR=always COLORTERM=truecolor -- \
    'log::info i')"
  check "always + truecolor: 24-bit One Dark blue for INFO" \
    matches "${result}" "${ESC}\[38;2;97;175;239mINFO"

  result="$(run_log TOOLCHAIN_LOG_COLOR=always -- 'log::warn w')"
  check "always without truecolor: 256-color yellow for WARN" \
    matches "${result}" "${ESC}\[38;5;180mWARN"

  result="$(run_log NO_COLOR=1 GITHUB_ACTIONS=true -- 'log::info i')"
  check "NO_COLOR wins over auto" lacks "${result}" "${ESC}"

  result="$(run_log NO_COLOR=1 TOOLCHAIN_LOG_COLOR=always -- 'log::info i')"
  check "TOOLCHAIN_LOG_COLOR=always wins over NO_COLOR" \
    matches "${result}" "${ESC}\["

  result="$(run_log GITHUB_ACTIONS=true NO_COLOR=1 -- \
    $'log::info i; log::warn "50% done\nnext"; log::error e')"
  check "Actions: warnings become escaped annotations" \
    matches "${result}" "::warning title=bash::50%25 done%0Anext"
  check "Actions: errors become annotations" \
    matches "${result}" "::error title=bash::e"
  check "Actions: info is not annotated" lacks "${result}" "::notice"

  # Log text can't run CI commands, with or without GITHUB_ACTIONS.
  local env
  for env in GITHUB_ACTIONS=true NOT_IN_ACTIONS=1; do
    result="$(run_log "${env}" NO_COLOR=1 -- \
      $'log::info "a\n::error::injected"; log::warn "b\r\n::add-mask::x"')"
    check "${env}: a message's line can't start a workflow command" \
      lacks "${result}" $'\n::error::injected'
    check "${env}: nor after a CR LF" lacks "${result}" $'\n::add-mask::x'
    check "${env}: continuation lines are indented" \
      matches "${result}" $'INFO  bash: a\n  ::error::injected'
    result="$(run_log "${env}" NO_COLOR=1 -- \
      'log::info "x ##vso[task.setvariable variable=PATH]/evil ##[group]g"')"
    check "${env}: Azure DevOps ##vso[ is broken up" \
      lacks "${result}" '##vso['
    check "${env}: and so is ##[" lacks "${result}" '##['
    check "${env}: the text stays readable" matches "${result}" \
      '# #vso\[task.setvariable variable=PATH\]/evil # #\[group\]g'
  done

  result="$(run_log TOOLCHAIN_LOG_COLOR=never -- $'log::info "50%\r60%"')"
  check "a lone CR becomes a line break, not run-together text" \
    matches "${result}" $'50%\n  60%'
  result="$(run_log TOOLCHAIN_LOG_COLOR=never -- $'log::info "one\ntwo"')"
  check "multi-line messages stay readable" matches "${result}" $'one\n  two'
  result="$(run_log GITHUB_ACTIONS=true NO_COLOR=1 \
    'TOOLCHAIN_LOG_TAG=a:b,c%d' -- 'log::warn w')"
  check "Actions: the annotation title gets property escaping" \
    matches "${result}" "::warning title=a%3Ab%2Cc%25d::w"
  result="$(run_log GITHUB_ACTIONS=true NO_COLOR=1 \
    $'TOOLCHAIN_LOG_TAG=x\n::add-mask::s' -- 'log::info hi')"
  check "the tag can't start a workflow command either" \
    lacks "${result}" $'\n::add-mask::s'

  result="$(run_log TOOLCHAIN_LOG_COLOR=never -- \
    '(log::fatal bye) || echo "rc=$?"')"
  check "log::fatal logs FATAL and exits 1" \
    matches "${result}" $'^rc=1\n--stderr--\n.*FATAL bash: bye'

  result="$(run_log TOOLCHAIN_LOG_COLOR=never -- \
    "source '${LIB_DIR}/log.sh'; log::info twice")"
  check "sourcing twice is harmless" matches "${result}" "INFO  bash: twice"

  return "${FAILED}"
}

main "$@"
