# Git helpers.

# gbf: fuzzy-switch to a local or remote branch.
gbf() {
  local branch
  branch="$(git branch --all --sort=-committerdate --format='%(refname:short)' \
    | grep -v '^origin$' | fzf --preview 'git log --oneline --graph --color=always -20 {}')" || return
  git switch "${branch#origin/}"
}

# groot: cd to the repository root.
groot() { cd "$(git rev-parse --show-toplevel)" || return; }

# gclean-merged: delete local branches already merged into the current branch.
gclean-merged() {
  git branch --merged | grep -vE '^\*|^\s*(main|master|develop)$' | xargs -r git branch -d
}
