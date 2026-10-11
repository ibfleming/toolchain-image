# Shell behavior.

setopt auto_cd # `dir` alone cds into it
setopt auto_pushd pushd_ignore_dups pushd_silent
setopt interactive_comments
setopt extended_glob
setopt no_beep
setopt no_flow_control # free up ^S / ^Q
setopt prompt_subst

WORDCHARS=${WORDCHARS//[\/.=-]/} # ^W / alt-backspace stop at path and flag separators
