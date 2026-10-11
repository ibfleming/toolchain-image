# Completion system. Tool completions (kubectl, helm, ...) are generated at image build
# time into /usr/local/share/zsh/site-functions, which is already on Debian's fpath.

fpath=("$TOOLCHAIN_ZSH_PLUGINS/zsh-completions/src"(N/) $fpath)

autoload -Uz compinit
# Full security check at most once a day; otherwise trust the cached dump (fast startup).
_tc_zcompdump="$XDG_CACHE_HOME/zsh/zcompdump-$ZSH_VERSION"
if [[ -n $_tc_zcompdump(#qN.mh+24) || ! -s $_tc_zcompdump ]]; then
  compinit -d "$_tc_zcompdump"
else
  compinit -C -d "$_tc_zcompdump"
fi
unset _tc_zcompdump

# OpenTofu ships bash-style completion only.
autoload -Uz bashcompinit && bashcompinit
(($+commands[tofu])) && complete -o nospace -C tofu tofu

zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "$XDG_CACHE_HOME/zsh/zcompcache"
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no # fzf-tab renders the menu
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*:git-checkout:*' sort false
