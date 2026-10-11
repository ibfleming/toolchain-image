# One Dark palette (Atom). Background is left to the terminal (`-1`) so it blends in.
#   fg #abb2bf  red #e06c75  green #98c379  yellow #e5c07b  blue #61afef
#   magenta #c678dd  cyan #56b6c2  orange #d19a66  comment #5c6370  gutter #3e4452

# LS_COLORS for ls, eza, fd and completion menus (vivid ships a one-dark theme).
if (($+commands[vivid])); then
  export LS_COLORS="$(vivid generate one-dark)"
fi

export BAT_THEME=OneHalfDark

export FZF_THEME_OPTS="\
--color=fg:#abb2bf,bg:-1,hl:#61afef \
--color=fg+:#e5c07b,bg+:#2c313a,hl+:#61afef \
--color=info:#98c379,prompt:#61afef,pointer:#e06c75 \
--color=marker:#98c379,spinner:#c678dd,header:#56b6c2 \
--color=border:#3e4452,gutter:-1,query:#abb2bf"
