# Emacs-style line editing plus the usual terminal keys.

bindkey -e

# Prefix-aware history search on ^P/^N and the arrow keys.
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search

# Word movement (ctrl/alt + arrows), home/end, delete.
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^[[1;3C' forward-word
bindkey '^[[1;3D' backward-word
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char
bindkey '^[[3;5~' kill-word
bindkey '^H' backward-kill-word # ctrl+backspace
bindkey '^[w' kill-region

# Edit the current command line in $EDITOR with ^X^E.
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# Esc Esc toggles a leading `sudo ` (recalls the previous command if the line is empty).
_tc_sudo_toggle() {
  [[ -z $BUFFER ]] && zle up-history
  if [[ $BUFFER == sudo\ * ]]; then
    BUFFER="${BUFFER#sudo }"
    ((CURSOR = CURSOR > 5 ? CURSOR - 5 : 0))
  else
    BUFFER="sudo $BUFFER"
    ((CURSOR += 5))
  fi
}
zle -N _tc_sudo_toggle
bindkey '^[^[' _tc_sudo_toggle
