#!/bin/bash
#
# Clipboard for the dev container, installed in the dev image as
# /usr/local/bin/xclip, ahead of the real /usr/bin/xclip, so tools that copy
# with xclip (gh's one-time codes, lazygit, scripts) reach your machine's
# clipboard in every setup:
#
#   1. A display (DISPLAY, which VS Code forwards to your machine, through
#      WSLg on Windows): the real xclip, for copying and pasting.
#   2. Otherwise, or if that fails: OSC 52, an escape sequence that asks the
#      terminal you're using to set its clipboard. Works in VS Code's
#      terminal, Windows Terminal, iTerm2, kitty, WezTerm and others, over
#      `./dev.sh --shell` and SSH too. Copying only: paste with your
#      terminal.
#
# Usage: like xclip. Copies STDIN, or the files named, to the clipboard
# (-selection clipboard|primary|secondary); -o prints it (display only).
# -f also prints the text, -r drops its last newline; -t and -loops apply
# with a display (OSC 52 takes only text).
#
# Exit status: 0 copied; 1 nothing could take it (no display, no terminal);
# 64 bad usage.

set -euo pipefail

readonly REAL_XCLIP="/usr/bin/xclip"
# Terminals cap OSC 52 payloads; stay well under the common limits.
readonly OSC52_MAX_BYTES=100000
# How often to check that a copy through the display has arrived (50 ms apart).
readonly WAIT_TRIES=40
# The text being copied, buffered so the OSC 52 fallback still has it after
# a failed display attempt (removed on exit).
DATA=""

# shellcheck source=image/lib/log.sh
source /usr/local/lib/toolchain/log.sh

#######################################
# Succeed when a local X display is there to try: DISPLAY names one and its
# socket exists.
# Globals:
#   DISPLAY
#######################################
display_available() {
  local number="${DISPLAY:-}"
  [[ "${number}" == :* ]] || return 1
  number="${number#:}"
  number="${number%%.*}"
  [[ -S "/tmp/.X11-unix/X${number}" && -x "${REAL_XCLIP}" ]]
}

#######################################
# Copy a file's contents to the terminal's clipboard with OSC 52.
# Globals:
#   OSC52_MAX_BYTES
# Arguments:
#   File, OSC 52 selection (c or p).
# Returns:
#   0 if written to the terminal, 1 if there is no terminal or the text is
#   too long.
#######################################
osc52_copy() {
  local file="$1"
  local selection="$2"
  local encoded
  encoded="$(base64 -w0 <"${file}")"
  if ((${#encoded} > OSC52_MAX_BYTES)); then
    log::error "too much text for the terminal's clipboard" \
      "(${#encoded} bytes encoded, at most ${OSC52_MAX_BYTES})"
    return 1
  fi
  if ! { printf '\033]52;%s;%s\a' "${selection}" "${encoded}" >/dev/tty; } \
    2>/dev/null; then
    log::error "no clipboard here: no display and no terminal" \
      "(run it in a terminal)"
    return 1
  fi
}

#######################################
# Succeed when an X selection target is text, which OSC 52 can carry.
# Arguments:
#   Target (empty: xclip's default, text).
#######################################
text_target() {
  case "$1" in
    "" | UTF8_STRING | STRING | TEXT | COMPOUND_TEXT | text/plain*) return 0 ;;
    *) return 1 ;;
  esac
}

#######################################
# Wait until the selection can be read, at most WAIT_TRIES x 50 ms. The real
# xclip forks first and claims the selection from the background, so it can
# return before the copy is there; a `copy; paste` right after would miss it.
# Asks for the targets, which every owner answers, whatever it holds.
# Globals:
#   REAL_XCLIP, WAIT_TRIES
# Arguments:
#   Selection, then options for the real xclip (e.g. -display).
#######################################
wait_for_owner() {
  local selection="$1"
  shift
  local -i try
  for ((try = 0; try < WAIT_TRIES; try++)); do
    if "${REAL_XCLIP}" "$@" -selection "${selection}" -t TARGETS -o \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
}

main() {
  local selection="clipboard" mode="in" target="" filter="" rmlastnl=""
  local arg
  # Options handed on to the real xclip; the display, also to wait_for_owner.
  local -a files=() options=() display=()
  while (($# > 0)); do
    arg="$1"
    shift
    case "${arg}" in
      -selection | -sel | -se)
        selection="${1:-}"
        shift || true
        ;;
      -o | -out) mode="out" ;;
      -f | -filter) filter=1 ;;
      -r | -rmlastnl) rmlastnl=1 ;;
      -noutf8) options+=("${arg}") ;;
      # Foreground modes; copying here always returns once the copy is there.
      -i | -in | -silent | -quiet | -verbose) ;;
      -target | -t)
        target="${1:-}"
        options+=("${arg}" "${target}")
        shift || true
        ;;
      -loops | -l)
        options+=("${arg}" "${1:-}")
        shift || true
        ;;
      -display | -d)
        display=("${arg}" "${1:-}")
        shift || true
        ;;
      -h | -help | -version)
        exec "${REAL_XCLIP}" "${arg}"
        ;;
      -*)
        log::error "unsupported option: ${arg}"
        return 64
        ;;
      *) files+=("${arg}") ;;
    esac
  done
  options+=("${display[@]}")

  if [[ "${mode}" == "out" ]]; then
    if display_available; then
      exec "${REAL_XCLIP}" "${options[@]}" -selection "${selection}" -o
    fi
    log::error "can't read the clipboard here (no display): paste with" \
      "your terminal instead (Ctrl+Shift+V, or Cmd+V on a Mac)"
    return 1
  fi

  DATA="$(mktemp)"
  trap 'rm -f -- "${DATA}"' EXIT
  cat -- "${files[@]:--}" >"${DATA}"
  # -f: the text also goes on, as it came in.
  if [[ -n "${filter}" ]]; then
    cat -- "${DATA}"
  fi
  if [[ -n "${rmlastnl}" && -s "${DATA}" &&
    "$(tail -c 1 -- "${DATA}" | od -An -tx1)" == " 0a" ]]; then
    truncate -s -1 -- "${DATA}"
  fi
  # The real xclip reads the text, then keeps serving it in the background:
  # in its own session, so closing the terminal doesn't end it (and the
  # copy with it), and with its output going nowhere, or a caller reading
  # ours would wait for it.
  if display_available \
    && setsid "${REAL_XCLIP}" "${options[@]}" -selection "${selection}" \
      -i "${DATA}" >/dev/null 2>&1; then
    wait_for_owner "${selection}" "${display[@]}"
    return 0
  fi
  if ! text_target "${target}"; then
    log::error "the terminal's clipboard only takes text, not ${target}" \
      "(needs a display)"
    return 1
  fi
  case "${selection}" in
    p*) osc52_copy "${DATA}" p ;; # primary, or its abbreviations
    *) osc52_copy "${DATA}" c ;;
  esac
}

main "$@"
