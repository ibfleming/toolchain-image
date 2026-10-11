# fzf: key bindings (^R history, ^T files, alt-c dirs), fd as the file source, bat/eza previews.
(($+commands[fzf])) || return 0

export FZF_DEFAULT_OPTS="--height=60% --layout=reverse --border=rounded --info=inline-right ${FZF_THEME_OPTS:-}"

if (($+commands[fd])); then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
  _fzf_compgen_path() { fd --hidden --follow --exclude .git . "$1"; }
  _fzf_compgen_dir() { fd --type d --hidden --follow --exclude .git . "$1"; }
fi

export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range=:300 {} 2>/dev/null || cat {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --icons --color=always {} 2>/dev/null || ls {}'"
export FZF_CTRL_R_OPTS="--preview 'echo {}' --preview-window=down:3:wrap"

# Key bindings + completion need the line editor; without a TTY (VS Code tasks, CI-style
# `zsh -i -c`) fzf's option save/restore fails with "can't change option: zle".
[[ -o zle && -t 0 ]] && source <(fzf --zsh)
