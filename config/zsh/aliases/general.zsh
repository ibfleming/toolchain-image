# General aliases.

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias -- -='cd -'

alias c='clear'
alias q='exit'
alias reload='exec zsh'
alias path='print -l $path'
alias x='chmod +x'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias mkdir='mkdir -p'

if (($+commands[eza])); then
  alias ls='eza --group-directories-first --icons=auto'
  alias l='eza -l --group-directories-first --icons=auto --git'
  alias ll='eza -l --group-directories-first --icons=auto --git -g'
  alias la='eza -la --group-directories-first --icons=auto --git -g'
  alias lt='eza --tree --level=2 --icons=auto --git-ignore'
else
  alias ls='ls --color=auto'
  alias ll='ls -lh'
  alias la='ls -lah'
fi

# `cat` is deliberately left alone (bat rejects cat flags like -v); use `b` for bat.
(($+commands[bat])) && alias b='bat'

(($+commands[nvim])) && alias vim='nvim' vi='nvim'
