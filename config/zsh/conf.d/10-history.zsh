# History: XDG location, large, shared across sessions, deduplicated.
# Persist it across container rebuilds by mounting a volume at ~/.local/state/zsh.

HISTFILE="$XDG_STATE_HOME/zsh/history"
HISTSIZE=100000
SAVEHIST=$HISTSIZE

setopt extended_history  # timestamps + durations
setopt share_history     # import new lines from other sessions; implies inc_append
setopt hist_ignore_space # ` cmd` stays out of history (secrets)
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_find_no_dups
setopt hist_reduce_blanks
setopt hist_verify # !! expansions are shown before running
