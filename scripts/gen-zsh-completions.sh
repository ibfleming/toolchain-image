#!/usr/bin/env bash
# Generate zsh completion functions for the pinned tools at image build time, so
# shells don't pay `source <(tool completion zsh)` on every start.
# Tools with completions built into zsh (git, go, cmake, make, ...) or wired up
# elsewhere (fzf, zoxide, tofu via bashcompinit) are not listed.
set -euo pipefail

dest="${1:-/usr/local/share/zsh/site-functions}"
mkdir -p "$dest"

gen() {
  local name="$1"
  shift
  "$@" >"$dest/_$name"
  [[ -s "$dest/_$name" ]] || {
    echo "gen-zsh-completions: empty output for $name" >&2
    exit 1
  }
}

gen kubectl kubectl completion zsh
gen helm helm completion zsh
gen k9s k9s completion zsh
gen uv uv generate-shell-completion zsh
gen uvx uvx --generate-shell-completion zsh
gen ruff ruff generate-shell-completion zsh
gen starship starship completions zsh
gen rg rg --generate complete-zsh
gen fd fd --gen-completions zsh
gen bat bat --completion zsh
gen delta delta --generate-completion zsh

echo "gen-zsh-completions: wrote $(find "$dest" -maxdepth 1 -type f | wc -l) completion files to $dest"
