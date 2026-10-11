# Plugins, baked into the image at pinned versions (no plugin manager, no runtime git clones).
# Order matters: fzf-tab after compinit; syntax-highlighting last, after all widgets exist.

_tc_plugin() {
  local file="$TOOLCHAIN_ZSH_PLUGINS/$1"
  [[ -r $file ]] && source "$file"
}

if _tc_plugin fzf-tab/fzf-tab.plugin.zsh; then
  zstyle ':fzf-tab:*' use-fzf-default-opts yes
  zstyle ':fzf-tab:*' switch-group '<' '>'
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --icons --color=always $realpath'
  zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'eza -1 --icons --color=always $realpath'
  zstyle ':fzf-tab:complete:kubectl-*:*' fzf-preview ''
fi

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#5c6370'
_tc_plugin zsh-autosuggestions/zsh-autosuggestions.zsh

_tc_plugin zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

unfunction _tc_plugin
