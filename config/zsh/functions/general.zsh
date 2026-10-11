# General-purpose shell functions.

# mkcd <dir>: create a directory (and parents) and cd into it.
mkcd() { mkdir -p -- "$1" && cd -- "$1"; }

# extract <archive>...: unpack by extension.
extract() {
  local f
  for f in "$@"; do
    [[ -f $f ]] || {
      print -u2 "extract: '$f' is not a file"
      return 1
    }
    case "$f" in
      *.tar.gz | *.tgz) tar -xzf "$f" ;;
      *.tar.xz | *.txz) tar -xJf "$f" ;;
      *.tar.bz2 | *.tbz2) tar -xjf "$f" ;;
      *.tar.zst) tar --zstd -xf "$f" ;;
      *.tar) tar -xf "$f" ;;
      *.gz) gunzip -k "$f" ;;
      *.xz) unxz -k "$f" ;;
      *.zip) unzip "$f" ;;
      *)
        print -u2 "extract: unknown archive type: $f"
        return 1
        ;;
    esac
  done
}

# fe [query]: fuzzy-find a file and open it in $EDITOR.
fe() {
  local file
  file="$(fzf --query="${1:-}" --select-1 --exit-0 \
    --preview 'bat --color=always --style=numbers --line-range=:300 {}')" && "${EDITOR:-vi}" "$file"
}

# fcd: fuzzy-cd into a subdirectory.
fcd() {
  local dir
  dir="$(fd --type d --hidden --exclude .git 2>/dev/null \
    | fzf --preview 'eza --tree --level=2 --icons --color=always {}')" && cd "$dir"
}

# fkill: fuzzy-pick processes to kill (signal defaults to TERM).
fkill() {
  local pids
  pids="$(ps -eo pid,user,%cpu,%mem,cmd --sort=-%cpu | sed 1d | fzf -m | awk '{print $1}')"
  [[ -n $pids ]] && print -r -- "$pids" | xargs kill -"${1:-TERM}"
}
