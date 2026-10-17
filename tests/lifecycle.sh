#!/bin/bash
#
# Tests for the lifecycle state library (scripts/lib/lifecycle.sh), the
# validation library (scripts/lib/validate.sh) and the dev-status, dev-wait
# and dev-reset commands, as installed in the dev image. Each case gets a
# fresh state directory.
#
# Usage: tests/lifecycle.sh  (inside the dev image, as vscode)

set -euo pipefail

readonly LIB_DIR="/usr/local/lib/toolchain"
STATE_ROOT=""
FAILED=0

#######################################
# Run a snippet in a clean bash that has sourced both libraries, with its
# own state directory.
# Globals:
#   LIB_DIR, STATE_ROOT
# Arguments:
#   Case name (the state directory), snippet.
# Outputs:
#   The snippet's STDOUT and STDERR, then "rc=<status>".
#######################################
run_case() {
  local rc=0 out
  out="$(env -i PATH="${PATH}" HOME="${HOME}" TOOLCHAIN_LOG_COLOR=never \
    TOOLCHAIN_STATE_DIR="${STATE_ROOT}/$1" bash -c \
    "set -euo pipefail; source '${LIB_DIR}/lifecycle.sh';
    source '${LIB_DIR}/validate.sh'; $2" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

#######################################
# Record one check.
# Globals:
#   FAILED
# Arguments:
#   Description, then a command; the check passes when it succeeds.
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
# Succeed when a file exists in a case's state directory.
# Globals:
#   STATE_ROOT
# Arguments:
#   Case name, file name.
#######################################
has() {
  [[ -f "${STATE_ROOT}/$1/$2" ]]
}

#######################################
# Succeed when a file does not exist in a case's state directory.
# Globals:
#   STATE_ROOT
# Arguments:
#   Case name, file name.
#######################################
lacks() {
  [[ ! -e "${STATE_ROOT}/$1/$2" ]]
}

# shellcheck disable=SC2016 # the snippets expand in the case's own bash
main() {
  local r
  STATE_ROOT="$(mktemp -d)"
  trap 'rm -rf "${STATE_ROOT}"' EXIT

  r="$(run_case fresh 'dev-status')"
  check "a fresh container is 'created' (dev-status exits 2)" \
    matches "${r}" $'^created\nrc=2$'

  r="$(run_case ok 'step() { echo hello; }
    lifecycle::stage post-create step; lifecycle::state; echo "state=${REPLY}"
    lifecycle::ready; dev-status')"
  check "a stage records started and done, with its output in a log" \
    has ok post-create.done
  check "the stage log holds the output" \
    grep -qx hello "${STATE_ROOT}/ok/post-create.log"
  check "done but not ready is 'partial'" matches "${r}" "state=partial"
  check "ready: dev-status exits 0 and lists the stage" \
    matches "${r}" $'ready\n  ✓ post-create +done .*\nrc=0$'

  r="$(run_case fail 'step() { false; touch "${TOOLCHAIN_STATE_DIR}/after"; }
    lifecycle::stage post-create step')"
  check "a failing step stops its stage, which returns its status" \
    matches "${r}" $'post-create: failed \\(exit 1\\).*\nrc=1$'
  check "nothing after the failing command ran" lacks fail after
  r="$(run_case fail 'dev-status')"
  check "the failure is recorded with its exit status" \
    matches "${r}" "post-create +failed +.* exit=1 "
  check "failed: dev-status exits 1" matches "${r}" $'\nrc=1$'

  r="$(run_case cond 'if lifecycle::stage post-create true; then echo ran
    else echo "refused=$?"; fi')"
  check "a stage called from a condition is refused (errexit is off there)" \
    matches "${r}" $'called from a condition.*\nrefused=2\n'
  check "and records nothing" lacks cond post-create.started

  r="$(run_case tag 'TOOLCHAIN_LOG_TAG=post-create \
    lifecycle::stage post-create true')"
  check "a script named after its stage doesn't repeat the stage name" \
    matches "${r}" "INFO  post-create: started"
  r="$(run_case tag2 'lifecycle::stage post-create true')"
  check "another script's progress lines name the stage" \
    matches "${r}" "INFO  bash: post-create: started"

  r="$(run_case color 'TOOLCHAIN_LOG_COLOR=always bash -c "
    source /usr/local/lib/toolchain/lifecycle.sh
    step() { log::info hello; printf \"\\e[1;31m red\\e[0m\\n\"; }
    lifecycle::stage post-create step"')"
  check "the terminal still gets colors" matches "${r}" $'\e\\[1;31m red'
  check "the stage log has no escape sequences" \
    bash -c "! grep -q \$'\\e' '${STATE_ROOT}/color/post-create.log'"
  check "and keeps the text" grep -q "INFO  bash: hello" \
    "${STATE_ROOT}/color/post-create.log"

  r="$(run_case rerun 'lifecycle::stage post-create true; lifecycle::ready
    lifecycle::stage post-start true; lifecycle::state; echo "state=${REPLY}"')"
  check "starting a stage clears ready" matches "${r}" "state=partial"

  r="$(run_case once 'n=0; step() { n=$((n + 1)); }
    lifecycle::once deps step; lifecycle::once deps step; echo "n=${n}"')"
  check "a once step runs once" matches "${r}" "n=1"
  check "and is skipped the second time" matches "${r}" "deps: already done"

  r="$(run_case once-fail 'lifecycle::stage post-create \
    lifecycle::once deps false')"
  check "a failing once step is not marked done" lacks once-fail deps.done

  r="$(run_case once 'dev-reset deps; n=0; step() { n=$((n + 1)); }
    lifecycle::once deps step; echo "n=${n}"')"
  check "dev-reset <marker> makes a once step run again" matches "${r}" "n=1"

  r="$(run_case ok 'dev-reset; dev-status -q')"
  check "dev-reset clears everything" matches "${r}" $'created\nrc=2$'

  r="$(run_case wait-ready 'lifecycle::ready; dev-wait -t 5')"
  check "dev-wait returns 0 when ready" matches "${r}" $'\nrc=0$'
  r="$(run_case fail 'dev-wait -t 5')"
  check "dev-wait returns 1 when a stage failed" matches "${r}" $'\nrc=1$'
  r="$(run_case fresh 'dev-wait -t 1')"
  check "dev-wait times out with 2" \
    matches "${r}" $'not ready after 1s .*\nrc=2$'
  r="$(run_case fresh 'dev-wait --bogus')"
  check "dev-wait rejects bad usage with 64" matches "${r}" $'\nrc=64$'

  r="$(run_case validate 'validate::tool bash; validate::tool no-such-tool
    validate::mount /etc; validate::env NOPE "set NOPE"; validate::report')"
  check "validate: passing checks log OK" matches "${r}" "OK +.*tool bash"
  check "validate: failures log their hint" \
    matches "${r}" "ERROR .*env NOPE: set NOPE"
  check "validate::report fails when any check failed" \
    matches "${r}" $'2 of 4 checks failed\nrc=1$'

  r="$(run_case validate 'validate::tool bash; validate::report')"
  check "validate::report starts counting again" \
    matches "${r}" $'all 1 checks passed\nrc=0$'

  r="$(run_case sign-ins 'validate::sign_ins')"
  check "validate::sign_ins warns, never fails" \
    matches "${r}" $'WARN .*ssh: .*\nrc=0$'

  return "${FAILED}"
}

main "$@"
