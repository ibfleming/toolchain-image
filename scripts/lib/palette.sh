# shellcheck shell=bash disable=SC2034 # variables are used by sourcing scripts
#
# One Dark palette for the toolchain's shell tooling: the same colors as
# the zsh theme, the welcome screen, fzf and the k9s skin. Each color has a
# 24-bit value (#rrggbb) and the nearest xterm 256-color index, for
# terminals without truecolor.
#
# Library: source it, don't run it. Installed in the images at
# /usr/local/lib/toolchain/palette.sh. Sourcing it twice is harmless.

[[ -n "${_TOOLCHAIN_PALETTE_LOADED:-}" ]] && return 0
readonly _TOOLCHAIN_PALETTE_LOADED=1

readonly PALETTE_FG='#abb2bf' PALETTE_FG_256=145
readonly PALETTE_DIM='#5c6370' PALETTE_DIM_256=59
readonly PALETTE_RED='#e06c75' PALETTE_RED_256=168
readonly PALETTE_GREEN='#98c379' PALETTE_GREEN_256=114
readonly PALETTE_YELLOW='#e5c07b' PALETTE_YELLOW_256=180
readonly PALETTE_BLUE='#61afef' PALETTE_BLUE_256=75
readonly PALETTE_PURPLE='#c678dd' PALETTE_PURPLE_256=176
readonly PALETTE_CYAN='#56b6c2' PALETTE_CYAN_256=73
readonly PALETTE_ORANGE='#d19a66' PALETTE_ORANGE_256=173
