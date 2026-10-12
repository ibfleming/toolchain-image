# welcome: the dev image's greeting. Shown once per container start (post.d/95-welcome);
# run `welcome` any time to see it again, `welcome --plain` for no color or box.
# Pure zsh: reads /etc/toolchain/{release,versions} (written at build time), runs no tools.

welcome() {
  emulate -L zsh
  setopt extended_glob

  local plain=0
  [[ ${1:-} == --plain || -n ${NO_COLOR:-} ]] && plain=1

  # --- data -------------------------------------------------------------------------------
  local -A rel ver
  local k v
  [[ -r /etc/toolchain/release ]] && while IFS='=' read -r k v; do rel[$k]=$v; done </etc/toolchain/release
  [[ -r /etc/toolchain/versions ]] && while IFS='=' read -r k v; do ver[${k##*/}]=$v; done </etc/toolchain/versions

  local version=${rel[TOOLCHAIN_VERSION]:-dev} revision=${rel[TOOLCHAIN_REVISION]:-}
  local created=${rel[TOOLCHAIN_CREATED]:-} source=${rel[TOOLCHAIN_SOURCE]:-}
  [[ $created == 1970-01-01 ]] && created=
  local os=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null)
  os=${${os#Debian GNU/Linux }:+Debian ${os#Debian GNU/Linux }}

  local kctx= kubeconfig=${${KUBECONFIG:-$HOME/.kube/config}%%:*}
  [[ -r $kubeconfig ]] && kctx=$(sed -n 's/^current-context: *//p' "$kubeconfig" 2>/dev/null)

  # --- palette (One Dark) and glyphs (Nerd Font) ------------------------------------------
  local blue='#61afef' purple='#c678dd' cyan='#56b6c2' green='#98c379' yellow='#e5c07b'
  local orange='#d19a66' red='#e06c75' fg='#abb2bf' dim='#5c6370'
  _welcome_c() { ((plain)) && print -rn -- "$2" || print -rn -- "%F{$1}${2//\%/%%}%f"; }

  # name  icon  color  version-key
  local -a tools=(
    "python" $'' $yellow python
    "node" $'' $green node
    "go" $'' $cyan go
    "tofu" $'\U000F1062' $purple opentofu
    "kubectl" $'\U000F10FE' $blue kubectl
    "helm" $'\U000F0833' $blue helm
    "k9s" $'' $cyan k9s
    "cmake" $'' $red CMake
    "claude" $'' $orange claude-code
  )

  # --- layout -----------------------------------------------------------------------------
  local -a rows=()
  # The logo in miniature: a container inside a hexagon, checked.
  local -a art=(
    "$(_welcome_c $blue ' ▗▄▀▀▀▀▄')$(_welcome_c $cyan $'')"
    "$(_welcome_c $blue ' ▐ ')$(_welcome_c $purple '████')$(_welcome_c $blue ' ▌')"
    "$(_welcome_c $blue ' ▐ ')$(_welcome_c $purple '████')$(_welcome_c $blue ' ▌')"
    "$(_welcome_c $blue ' ▝▀▄▄▄▄▀▘')"
  )

  local title="$(_welcome_c $fg toolchain)$(_welcome_c $dim ' · ')$(_welcome_c $purple dev)"
  title+="$(_welcome_c $dim '  ')$(_welcome_c $cyan "v$version")"
  local plat="$(_welcome_c $dim "${os:-Linux} · $(uname -m) · zsh $ZSH_VERSION")"
  local build="${revision:+$(_welcome_c $dim "${revision[1,7]}")}${created:+$(_welcome_c $dim " · built $created")}"
  local more="$(_welcome_c $dim "${${source#https://}:-overrides: ~/.config/zsh/local.zsh}")"
  rows+=("${art[1]}  $title" "${art[2]}  $plat" "${art[3]}  $build" "${art[4]}  $more" "--")

  # Three tools per row, each cell padded to a fixed width. `shift` walks the table four
  # fields at a time (arithmetic subscripts get reformatted by shfmt into invalid zsh).
  local -a t=("${tools[@]}")
  local n=0 cell line=""
  while (($#t)); do
    cell="$(_welcome_c $t[3] "$t[2]") $(_welcome_c $fg "$t[1]") $(_welcome_c $dim "${ver[$t[4]]:-–}")"
    line+=$cell$(_welcome_pad "$cell" 21)
    shift 4 t
    if ((++n % 3 == 0)); then
      rows+=("$line")
      line=""
    fi
  done
  [[ -n $line ]] && rows+=("$line")
  rows+=("--")

  [[ -n $kctx ]] && rows+=("$(_welcome_c $blue $'\U000F10FE') $(_welcome_c $dim 'kube')  $(_welcome_c $fg "$kctx")")
  # Shortcuts: pairs of key and what it does, joined with two spaces.
  _welcome_keys() {
    local out= k d
    while (($#)); do
      k=$1 d=$2
      shift 2
      out+="${out:+  }$(_welcome_c $yellow "$k")${d:+ $(_welcome_c $dim "$d")}"
    done
    print -rn -- "$out"
  }
  rows+=("$(_welcome_keys k kubectl kctx/kns ctx/ns lg lazygit tf tofu z jump)")
  rows+=("$(_welcome_keys '^R' history '^T' files 'Esc Esc' sudo fe/fcd fuzzy versions '')")
  rows+=("$(_welcome_c $dim "welcome to see this again · TOOLCHAIN_WELCOME=always|once|off")")

  # --- render -----------------------------------------------------------------------------
  local width=66 r
  if ((plain)) || ((COLUMNS < width + 4)); then
    for r in "${rows[@]}"; do
      if [[ $r == -- ]]; then print; elif ((plain)); then print -r -- "$r"; else print -P -- "$r"; fi
    done
  else
    local bar=${(l:width::─:)}
    print -P -- "$(_welcome_c $dim "╭${bar}╮")"
    for r in "${rows[@]}"; do
      if [[ $r == -- ]]; then
        print -P -- "$(_welcome_c $dim "├${bar}┤")"
      else
        print -P -- "$(_welcome_c $dim '│') ${r}$(_welcome_pad "$r" $((width - 2))) $(_welcome_c $dim '│')"
      fi
    done
    print -P -- "$(_welcome_c $dim "╰${bar}╯")"
  fi
  unfunction _welcome_c _welcome_keys
}

# Spaces needed to pad a prompt-escaped string to a display width. Counts characters, not
# wcwidth: every glyph used here (box drawing, blocks, Nerd Font icons) is one column wide in a
# Nerd Font Mono terminal font, while zsh's wcwidth reports supplementary-plane icons as 0.
_welcome_pad() {
  emulate -L zsh
  setopt extended_glob
  local s=${1//\%F\{[^\}]#\}/}
  s=${s//\%f/}
  s=${s//\%\%/%}
  local n=$(($2 - ${#s}))
  ((n > 0)) && print -rn -- "${(l:n:: :)}"
}
