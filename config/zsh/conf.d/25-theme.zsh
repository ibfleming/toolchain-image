# Color theme shared by ls/eza, fzf, bat and delta. One theme ships today: one-dark.
# Override with TOOLCHAIN_THEME before sourcing; a theme is themes/<name>.zsh.

: "${TOOLCHAIN_THEME:=one-dark}"
if [[ -r "$TOOLCHAIN_ZSH/themes/$TOOLCHAIN_THEME.zsh" ]]; then
  source "$TOOLCHAIN_ZSH/themes/$TOOLCHAIN_THEME.zsh"
else
  print -u2 "toolchain-zsh: theme '$TOOLCHAIN_THEME' not found in $TOOLCHAIN_ZSH/themes"
fi
