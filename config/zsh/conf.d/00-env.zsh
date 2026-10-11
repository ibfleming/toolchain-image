# Environment and PATH for interactive shells.
# Image-wide variables (GOTOOLCHAIN, NPM_CONFIG_PREFIX, ...) are set as Docker ENV instead,
# so non-interactive processes such as VS Code extensions see them too.

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$XDG_STATE_HOME/zsh" "$XDG_CACHE_HOME/zsh" "$XDG_DATA_HOME/zsh"

# Unique, ordered PATH. User bins go LAST (only if they exist) so they can't shadow
# root-owned system tools (claude, git, kubectl, ...).
typeset -gU path fpath
path=($path "$HOME/.local/bin"(N/) "$HOME/go/bin"(N/))

if (($+commands[nvim])); then
  export EDITOR=nvim VISUAL=nvim
else
  export EDITOR=vi VISUAL=vi
fi

export PAGER=less
export LESS='-R -F -X -i -M'
export LESSHISTFILE="$XDG_STATE_HOME/less/history"
export PYTHONIOENCODING=UTF-8
