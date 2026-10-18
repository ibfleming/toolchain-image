# copy and paste: the clipboard from any shell, with whatever clipboard is there. In the dev
# image that's its xclip bridge (the display VS Code forwards, or OSC 52 through the terminal);
# on a host, the system's own (macOS, WSL, Wayland, X), or OSC 52 when there's none.
#
#   <command> | copy     copy a command's output
#   copy <file>...       copy files
#   paste                print the clipboard
#
# paste with arguments, or with input piped in, is the standard paste(1), unchanged.

# Succeed when a command is on PATH. (Not $+commands[...]: shfmt, which formats these files as
# bash, rewrites a subscript like wl-copy as arithmetic.)
_clip_has() { whence -p -- "$1" >/dev/null; }

# Set REPLY to the clipboard to use here: xclip, macos, wsl, wayland, or osc52.
_clip_backend() {
  if [[ -n ${WSL_DISTRO_NAME:-} ]] && _clip_has clip.exe; then
    REPLY=wsl
  elif _clip_has pbcopy; then
    REPLY=macos
  elif [[ -n ${WAYLAND_DISPLAY:-} ]] && _clip_has wl-copy; then
    REPLY=wayland
  elif _clip_has xclip; then
    REPLY=xclip
  else
    REPLY=osc52
  fi
}

# copy [file...]: put STDIN, or the files, on the clipboard.
copy() {
  if (($# == 0)) && [[ -t 0 ]]; then
    print -u2 'usage: <command> | copy, or copy <file>...'
    return 64
  fi
  _clip_backend
  case $REPLY in
    xclip) xclip -selection clipboard "$@" ;;
    macos) cat -- "${@:--}" | pbcopy ;;
    wayland) cat -- "${@:--}" | wl-copy ;;
    # clip.exe takes UTF-16 with a byte-order mark; plain UTF-8 would garble non-ASCII text.
    wsl) { printf '\xff\xfe' && cat -- "${@:--}" | iconv -f UTF-8 -t UTF-16LE; } | clip.exe ;;
    osc52)
      local encoded
      encoded=$(cat -- "${@:--}" | base64 | tr -d '\n') || return
      { printf '\e]52;c;%s\a' "$encoded" >/dev/tty; } 2>/dev/null || {
        print -u2 'copy: no clipboard here (no terminal)'
        return 1
      }
      ;;
  esac
}

# paste: print the clipboard. With arguments or piped input, it's paste(1).
paste() {
  if (($# > 0)) || [[ ! -t 0 ]]; then
    command paste "$@"
    return
  fi
  _clip_backend
  case $REPLY in
    xclip) xclip -selection clipboard -o ;;
    macos) pbpaste ;;
    wayland) wl-paste --no-newline ;;
    # As UTF-8, without the CRs, the byte-order mark Windows adds, or a trailing newline.
    wsl)
      powershell.exe -NoProfile -Command \
        '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); [Console]::Out.Write((Get-Clipboard -Raw))' \
        | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//'
      ;;
    osc52)
      print -u2 "paste: can't read the clipboard here; paste with your terminal instead"
      return 1
      ;;
  esac
}
