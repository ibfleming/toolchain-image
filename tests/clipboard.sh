#!/bin/bash
#
# Tests for the dev image's clipboard and browser bridges (scripts/
# clipboard.sh as xclip, scripts/xdg_open.sh as xdg-open): OSC 52 through a
# terminal, the real xclip on a display (Xvfb, installed for the test, so it
# needs network), the fallbacks and their errors.
#
# Usage: tests/clipboard.sh  (inside the dev image, as vscode)

set -euo pipefail

readonly ESC=$'\e'
readonly BEL=$'\a'
# The image's interactive zsh (copy and paste are its functions), quietly.
readonly ZSH_I="TOOLCHAIN_WELCOME=off zsh -ic"
FAILED=0

#######################################
# Run a command line in a pseudo-terminal, as an interactive terminal would.
# Arguments:
#   Command line (run by sh).
# Outputs:
#   Everything written to the terminal (CRs removed), then "rc=<status>".
#######################################
in_terminal() {
  local out rc=0
  out="$(script -qec "$1" /dev/null </dev/null)" || rc=$?
  printf '%s\nrc=%s\n' "${out//$'\r'/}" "${rc}"
}

#######################################
# Run a command line without a terminal.
# Arguments:
#   Command line (run by sh).
# Outputs:
#   Its STDOUT and STDERR, then "rc=<status>".
#######################################
no_terminal() {
  local out rc=0
  out="$(sh -c "$1" </dev/null 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

#######################################
# Print the OSC 52 sequence that sets a selection to a text.
# Arguments:
#   Selection (c or p), text.
#######################################
osc52() {
  printf '%s]52;%s;%s%s' "${ESC}" "$1" "$(printf '%s' "$2" | base64 -w0)" \
    "${BEL}"
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
# Succeed when a string contains another.
# Arguments:
#   String, substring.
#######################################
has() {
  [[ "$1" == *"$2"* ]]
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
  local r browser_log
  unset DISPLAY BROWSER

  check "gh and other tools find the bridge first on PATH" \
    test "$(command -v xclip)" = /usr/local/bin/xclip
  check "and xdg-open" test "$(command -v xdg-open)" = /usr/local/bin/xdg-open

  r="$(in_terminal 'printf "one-time code" | xclip -selection clipboard')"
  check "no display: copies with OSC 52 through the terminal" \
    has "${r}" "$(osc52 c 'one-time code')"
  check "and succeeds" has "${r}" "rc=0"
  r="$(in_terminal 'printf "sel" | xclip -selection primary')"
  check "the primary selection maps to OSC 52's p" has "${r}" "$(osc52 p sel)"
  r="$(in_terminal 'printf "from a file" > /tmp/f && xclip /tmp/f')"
  check "copies a named file" has "${r}" "$(osc52 c 'from a file')"
  r="$(in_terminal 'printf dead | DISPLAY=:9 xclip -selection clipboard')"
  check "a display without a server falls back to OSC 52" \
    has "${r}" "$(osc52 c dead)"

  r="$(no_terminal 'printf x | xclip -selection clipboard')"
  check "no display and no terminal: fails and says why" \
    has "${r}" $'no clipboard here'
  check "with status 1" has "${r}" "rc=1"
  r="$(in_terminal 'head -c 80000 /dev/zero | xclip')"
  check "refuses more than a terminal's clipboard takes" \
    has "${r}" "too much text"
  r="$(no_terminal 'xclip -o')"
  check "no display: paste points at the terminal's paste" \
    has "${r}" "paste with your terminal"
  r="$(no_terminal 'xclip -bogus </dev/null')"
  check "rejects unknown options with 64" has "${r}" "rc=64"

  browser_log="$(mktemp)"
  # shellcheck disable=SC2016 # $1 belongs to the fake browser script
  printf '#!/bin/sh\necho "$1" >%s\n' "${browser_log}" >/tmp/browser
  chmod +x /tmp/browser
  r="$(no_terminal 'BROWSER=/tmp/browser xdg-open https://example.com/a')"
  check "xdg-open hands the URL to \$BROWSER (VS Code's helper)" \
    grep -qx 'https://example.com/a' "${browser_log}"
  check "and says nothing else" lacks "${r}" "open this"
  r="$(in_terminal 'xdg-open https://example.com/b')"
  check "no \$BROWSER: xdg-open prints the URL" \
    has "${r}" "open this in your browser: https://example.com/b"
  check "and copies it" has "${r}" "$(osc52 c https://example.com/b)"

  r="$(in_terminal "${ZSH_I} 'print -n hi | copy'")"
  check "zsh copy: a command's output, through OSC 52" \
    has "${r}" "$(osc52 c hi)"
  r="$(in_terminal "${ZSH_I} 'print -n filed > /tmp/g; copy /tmp/g'")"
  check "zsh copy: a file" has "${r}" "$(osc52 c filed)"
  r="$(in_terminal "${ZSH_I} 'copy'")"
  check "zsh copy with nothing to copy shows its usage" \
    has "${r}" "usage: <command> | copy"
  r="$(in_terminal "${ZSH_I} 'paste'")"
  check "zsh paste without a display points at the terminal's paste" \
    has "${r}" "paste with your terminal"
  r="$(in_terminal "${ZSH_I} 'print -l a b >/tmp/p1; print -l 1 2 >/tmp/p2
    paste /tmp/p1 /tmp/p2'")"
  check "zsh paste with files is still paste(1)" has "${r}" $'a\t1\nb\t2'
  r="$(in_terminal "${ZSH_I} 'print piped | paste'")"
  check "and with piped input" has "${r}" "piped"

  if ! sudo apt-get update -qq >/dev/null 2>&1 \
    || ! sudo apt-get install -y -qq --no-install-recommends xvfb \
      >/dev/null 2>&1; then
    printf 'FAIL could not install Xvfb for the display checks\n'
    return 1
  fi
  Xvfb :5 -nolisten tcp >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S /tmp/.X11-unix/X5 ]] && break
    sleep 0.5
  done
  r="$(in_terminal \
    'printf "via display" | DISPLAY=:5 xclip -selection clipboard')"
  check "with a display: copies through the real xclip" \
    lacks "${r}" "]52;"
  r="$(no_terminal 'DISPLAY=:5 xclip -selection clipboard -o')"
  check "and pastes from it" has "${r}" "via display"
  r="$(in_terminal \
    "DISPLAY=:5 ${ZSH_I} 'print -n round-trip | copy; paste'")"
  check "zsh copy, then paste, through the display" has "${r}" "round-trip"
  pkill -x Xvfb || true

  return "${FAILED}"
}

main "$@"
