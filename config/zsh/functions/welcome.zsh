# welcome: the dev image's greeting, shown once per container start by post.d/95-welcome.
#   welcome          the greeting            welcome tools    every pinned tool, and what changed
#   welcome keys     aliases and bindings    welcome --plain  any view without color or box
# Pure zsh without subshells: reads /etc/toolchain/{release,versions,previous} (written at build
# time) and checks a few files and variables for the status row. It runs no tools, so it's instant.

welcome() {
  emulate -L zsh
  setopt extended_glob
  local plain=0 view=main a
  [[ -n ${NO_COLOR:-} ]] && plain=1
  for a in "$@"; do
    case $a in
      --plain) plain=1 ;;
      tools | keys) view=$a ;;
      help | -h | --help) view=help ;;
      *)
        print -ru2 -- "welcome: unknown argument '$a' (see welcome --help)"
        return 2
        ;;
    esac
  done

  # --- data -------------------------------------------------------------------------------
  local -A rel ver prev
  local k v
  [[ -r /etc/toolchain/release ]] && while IFS='=' read -r k v; do rel[$k]=$v; done </etc/toolchain/release
  [[ -r /etc/toolchain/versions ]] && while IFS='=' read -r k v; do ver[${k##*/}]=$v; done </etc/toolchain/versions
  [[ -r /etc/toolchain/previous ]] && while IFS='=' read -r k v; do
    [[ -n $k ]] && prev[${k##*/}]=$v
  done </etc/toolchain/previous
  local version=${rel[TOOLCHAIN_VERSION]:-dev} since=${rel[TOOLCHAIN_PREVIOUS]:-}

  # What changed since the previous release: ↑ a different version, + a new tool.
  local -A mark
  local -i updated=0 added=0
  if (($#prev)); then
    for k in ${(k)ver}; do
      if [[ -z ${prev[$k]:-} ]]; then
        mark[$k]=+
        ((added++))
      elif [[ ${prev[$k]} != "${ver[$k]}" ]]; then
        mark[$k]=↑
        ((updated++))
      fi
    done
  fi

  # --- palette (One Dark) -----------------------------------------------------------------
  local blue='#61afef' purple='#c678dd' cyan='#56b6c2' green='#98c379' yellow='#e5c07b'
  local orange='#d19a66' red='#e06c75' fg='#abb2bf' dim='#5c6370'
  local -i width=66
  local -a rows=()

  case $view in
    main) _welcome_main ;;
    tools) _welcome_tools ;;
    keys) _welcome_keys ;;
    help) _welcome_help ;;
  esac
  _welcome_render
}

# The greeting: logo and build, project and status, tool pins, shortcuts, a tip of the day.
_welcome_main() {
  # Logo: "toolchain" in thin box-drawing letters, on a blue -> purple ramp.
  local -a top=('╺┳╸' '┏━┓' '┏━┓' '╻  ' '┏━╸' '╻ ╻' '┏━┓' '╻' '┏┓╻')
  local -a mid=(' ┃ ' '┃ ┃' '┃ ┃' '┃  ' '┃  ' '┣━┫' '┣━┫' '┃' '┃┗┫')
  local -a bot=(' ╹ ' '┗━┛' '┗━┛' '┗━╸' '┗━╸' '╹ ╹' '╹ ╹' '╹' '╹ ╹')
  local w1=" " w2=" " w3=" " j
  for j in {1..9}; do
    _welcome_mix $blue $purple $((j - 1)) 8
    w1+="%F{$REPLY}$top[j] %f"
    w2+="%F{$REPLY}$mid[j] %f"
    w3+="%F{$REPLY}$bot[j] %f"
  done

  local os= line
  if [[ -r /etc/os-release ]]; then
    for line in ${(f)"$(</etc/os-release)"}; do
      [[ $line == PRETTY_NAME=* ]] && os=${${line#PRETTY_NAME=}//\"/}
    done
  fi
  # Short and stable: "Debian GNU/Linux 13 (trixie)" -> "Debian 13",
  # "Ubuntu 24.04.5 LTS" -> "Ubuntu 24.04" (no codename, LTS or point release).
  os=${${${os/GNU\/Linux /}% \(*\)}% LTS}
  [[ $os =~ '^(.* [0-9]+\.[0-9]+)\.[0-9]+$' ]] && os=$match[1]
  local revision=${rel[TOOLCHAIN_REVISION]:-} created=${rel[TOOLCHAIN_CREATED]:-}
  local -a meta=()
  [[ -n $revision ]] && meta+=("${revision[1,7]}")
  [[ -n $created && $created != 1970-01-01 ]] && meta+=("built $created")
  rows+=(
    "$w1 %F{$purple}dev%f  %F{$cyan}v$version%f"
    "$w2 %F{$dim}${os:-Linux} · $CPUTYPE · zsh $ZSH_VERSION%f"
    "$w3 %F{$dim}${(j: · :)meta}%f"
    --
  )

  # Project: the git repository the shell started in (.git is a file in worktrees).
  local dir=$PWD gitdir= left=
  while [[ -z $gitdir ]]; do
    if [[ -d $dir/.git ]]; then
      gitdir=$dir/.git
    elif [[ -f $dir/.git ]]; then
      gitdir=${$(<$dir/.git)#gitdir: }
      [[ $gitdir == /* ]] || gitdir=$dir/$gitdir
    elif [[ $dir == / ]]; then
      break
    else
      dir=${dir:h}
    fi
  done
  if [[ -r $gitdir/HEAD ]]; then
    local head=$(<$gitdir/HEAD) branch
    if [[ $head == 'ref: refs/heads/'* ]]; then branch=${head#ref: refs/heads/}; else branch=${head[1,7]}; fi
    _welcome_trunc ${dir:t} 22
    left="%F{$blue}"$''"%f %F{$fg}$REPLY%f"
    _welcome_trunc $branch 20
    left+="  %F{$orange}"$''"%f %F{$fg}$REPLY%f"
  fi

  # Status: signed in to Claude Code and the GitHub CLI, a git identity, a forwarded SSH agent, a
  # kube context.
  local -i ok
  local right= f kctx= kubeconfig=${${KUBECONFIG:-$HOME/.kube/config}%%:*}
  local claude_creds=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
  [[ -s $claude_creds || -n ${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-} ]]
  _welcome_flag claude $?
  right+=$REPLY
  [[ -n ${GH_TOKEN:-} || -s ${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml ]]
  _welcome_flag gh $?
  right+="  $REPLY"
  ok=1
  [[ -n ${GIT_AUTHOR_EMAIL:-} ]] && ok=0
  for f in $HOME/.gitconfig ${XDG_CONFIG_HOME:-$HOME/.config}/git/config; do
    [[ -r $f && "$(<$f)" == *email* ]] && ok=0
  done
  _welcome_flag git $ok
  right+="  $REPLY"
  [[ -S ${SSH_AUTH_SOCK:-} ]]
  _welcome_flag ssh $?
  right+="  $REPLY"
  if [[ -r $kubeconfig ]]; then
    for line in ${(f)"$(<$kubeconfig)"}; do
      [[ $line == current-context:* ]] && kctx=${${${line#current-context:}## #}//[\"\']/}
    done
  fi
  [[ -n $kctx ]]
  _welcome_flag kube $?
  right+="  $REPLY"
  if [[ -n $kctx ]]; then
    _welcome_trunc $kctx 18
    right+=" %F{$fg}$REPLY%f"
  fi
  _welcome_len "$left"
  local -i lw=$REPLY
  _welcome_len "$right"
  if [[ -n $left ]] && ((lw + 2 + REPLY <= width - 2)); then
    rows+=("$left${(l:width - 2 - lw - REPLY:: :)}$right" --)
  else
    [[ -n $left ]] && rows+=("$left")
    rows+=("$right" --)
  fi

  # Tools: name, Nerd Font icon, color, version key. Three per row.
  local -a tools=(
    python $'' $yellow python
    node $'' $green node
    go $'' $cyan go
    tofu $'\U000F1062' $purple opentofu
    kubectl $'\U000F10FE' $blue kubectl
    helm $'\U000F0833' $blue helm
    k9s $'' $cyan k9s
    cmake $'' $red CMake
    gh $'\uf09b' $fg cli
  )
  local cell row=
  local -i n=0
  # `shift` walks the table four fields at a time (shfmt reformats arithmetic subscripts
  # into invalid zsh).
  while (($#tools)); do
    k=$tools[4]
    cell="%F{$tools[3]}$tools[2]%f %F{$fg}$tools[1]%f %F{$dim}${ver[$k]:-–}%f"
    [[ -n ${mark[$k]:-} ]] && cell+=" %F{$green}${mark[$k]}%f"
    _welcome_len "$cell"
    row+="$cell${(l:21 - REPLY:: :)}"
    shift 4 tools
    if ((++n % 3 == 0)); then
      rows+=("$row")
      row=
    fi
  done
  [[ -n $row ]] && rows+=("$row")
  if ((updated + added)); then
    _welcome_since
    rows+=("$REPLY %F{$dim}· welcome tools%f")
  fi
  rows+=(--)

  _welcome_pack k kubectl kctx/kns ctx/ns lg lazygit lzd lazydocker tf tofu z jump \
    '^R' history '^T' files 'Esc Esc' sudo fe/fcd fuzzy versions ''

  # Tip of the day: one per day of the year, in order.
  local -a tips=(
    'Alt-C fuzzy-cds into a subdirectory, with a tree preview'
    'Type a prefix, then Up: history search for that prefix'
    'Ctrl-X Ctrl-E opens the current command line in your editor'
    'Esc Esc puts sudo in front of the command (or takes it off)'
    'Tab opens a fuzzy menu when there are several completions'
    'zi picks a recent directory interactively, z - jumps back'
    'gbf fuzzy-switches to any local or remote git branch'
    'groot jumps to the root of the current repository'
    'gclean-merged deletes local branches already merged'
    'gpf force-pushes with --force-with-lease, never plain --force'
    'glo is a compact git log graph; gloa shows every branch'
    'kge lists cluster events, oldest first, newest at the bottom'
    'kl <pod> follows its logs, starting from the last 200 lines'
    'k9s, then :ctx, switches the Kubernetes context'
    'hl lists every Helm release in every namespace'
    'cmb configures and builds a CMake project with Ninja'
    'uvr runs a command inside the uv project environment'
    'lt shows a two-level tree that respects .gitignore'
    'fkill fuzzy-picks processes to kill'
    'extract unpacks an archive of any common format'
    'mkcd <dir> creates a directory and changes into it'
    'Your own aliases go in ~/.config/zsh/local.zsh'
    'reload restarts zsh after you change its config'
    'welcome keys lists every alias, function and binding'
  )
  zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS
  local doy
  strftime -s doy %j $EPOCHSECONDS
  local -i t=$((10#$doy % $#tips + 1))
  rows+=("%F{$yellow}"$''"%f %F{$dim}tip%f  %F{$fg}$tips[t]%f" --)
  rows+=("%F{$dim}welcome [tools|keys|--help] · TOOLCHAIN_WELCOME=always|once|off%f")
}

# Every pinned tool, sorted, two per row, with what changed since the previous release.
_welcome_tools() {
  rows+=("%F{$fg}toolchain%f %F{$dim}·%f %F{$purple}dev%f  %F{$cyan}v$version%f %F{$dim}· $#ver tools pinned%f")
  if (($#prev)); then
    _welcome_since
    rows+=("$REPLY")
  fi
  rows+=(--)
  local name cell row=
  local -i n=0
  for name in ${(oi)${(k)ver}}; do
    cell="%F{$fg}${(L)name}%f %F{$dim}${ver[$name]}%f"
    case ${mark[$name]:-} in
      ↑) cell+=" %F{$green}↑ ${prev[$name]}%f" ;;
      +) cell+=" %F{$green}+ new%f" ;;
    esac
    _welcome_len "$cell"
    row+="$cell${(l:32 - REPLY:: :)}"
    if ((++n % 2 == 0)); then
      rows+=("$row")
      row=
    fi
  done
  [[ -n $row ]] && rows+=("$row")
  ((n)) || rows+=("%F{$dim}no /etc/toolchain/versions in this image%f")
}

# Aliases, functions and key bindings, by topic.
_welcome_keys() {
  rows+=("%F{$purple}shell%f")
  _welcome_pack '^R' history '^T' 'insert file' Alt-C cd 'Esc Esc' sudo '^X^E' editor \
    'prefix+Up' 'history search' Tab 'fuzzy menu' reload 'restart zsh' path '$PATH' x 'chmod +x'
  rows+=(-- "%F{$purple}files%f")
  _welcome_pack z jump zi 'pick dir' 'z -' back fe 'edit file' fcd cd 'l/ll/la' list lt tree b bat \
    mkcd 'mkdir+cd' extract unpack fkill 'kill process' '.. ...' up
  rows+=(-- "%F{$purple}git%f")
  _welcome_pack g git gs status ga/gaa add gap 'add -p' gc commit gca amend gd diff gds staged \
    gf fetch gl pull gp push gpf 'push --lease' gsw/gswc switch gb branches gbf 'fuzzy branch' \
    gst/gstp stash glo/gloa log groot 'repo root' gclean-merged '' lg lazygit
  rows+=(-- "%F{$purple}kubernetes%f")
  _welcome_pack k kubectl kg/kga get kgp pods kgpw 'watch pods' kgs/kgd/kgi/kgn '' kd/kdp describe \
    kl logs kex exec ka apply kdel delete kge events kpf port-forward krr/krs rollout ktop top \
    kctx context kns namespace k9 k9s h helm hl releases
  rows+=(-- "%F{$purple}build%f")
  _welcome_pack tf tofu tfi/tfp/tfa 'init/plan/apply' tfv/tff 'validate/fmt' uvr 'uv run' uvs 'uv sync' \
    cmb 'cmake+ninja build' versions 'pinned tools'
}

_welcome_help() {
  rows+=(
    "%F{$fg}welcome%f %F{$dim}[tools|keys] [--plain]%f"
    --
    "%F{$yellow}welcome%f        %F{$dim}the greeting: build, project, status, tools, tips%f"
    "%F{$yellow}welcome tools%f  %F{$dim}all pinned tools and what changed%f"
    "%F{$yellow}welcome keys%f   %F{$dim}aliases, functions and key bindings%f"
    "%F{$yellow}--plain%f        %F{$dim}no color or box (also when NO_COLOR is set)%f"
    --
    "%F{$fg}TOOLCHAIN_WELCOME%f %F{$dim}when new terminals show the greeting:%f"
    "  %F{$yellow}once%f %F{$dim}per container start (default) ·%f %F{$yellow}always%f %F{$dim}·%f %F{$yellow}off%f"
    "%F{$dim}status: %F{$green}●%f%F{$dim} ready, %f○%F{$dim} not set up (claude and gh sign-in,%f"
    "%F{$dim}git email, ssh agent, kube context)%f"
  )
}

# Print $rows: boxed with a gradient frame, unboxed when the terminal is narrow, or without any
# color (--plain, NO_COLOR). A row of `--` is a separator. The box is as wide as its widest row
# (at least $width), so every border lines up; it never grows past the terminal, and rows that
# would are cut with an ellipsis.
_welcome_render() {
  # Rows hold literal text such as `$PATH`; print -P must not expand it (starship sets prompt_subst).
  setopt local_options no_prompt_subst no_prompt_bang
  local r
  local -i inner=$width
  if ((plain)); then
    for r in "${rows[@]}"; do
      if [[ $r == -- ]]; then
        print
      else
        r=${r//\%[FK]\{[^\}]#\}/}
        r=${r//\%[fk]/}
        print -r -- "${r//\%\%/%}"
      fi
    done
  elif ((COLUMNS < width + 4)); then
    for r in "${rows[@]}"; do
      if [[ $r == -- ]]; then print; else print -P -- "$r"; fi
    done
  else
    for r in "${rows[@]}"; do
      [[ $r == -- ]] && continue
      _welcome_len "$r"
      ((REPLY + 2 > inner)) && inner=$((REPLY + 2))
    done
    ((inner > COLUMNS - 4)) && inner=$((COLUMNS - 4))
    # One left-to-right gradient for the whole frame: each column of the top, bottom and
    # separator lines gets its color, so the left edge is the first color and the right the last.
    local top= bottom= sep= c1 c2 c3 left right
    local -i i last=$((inner + 1))
    for ((i = 0; i <= last; i++)); do
      c1=─ c2=─ c3=─
      ((i == 0)) && c1=╭ c2=╰ c3=├
      ((i == last)) && c1=╮ c2=╯ c3=┤
      _welcome_mix $blue $purple $i $last
      ((i == 0)) && left=$REPLY
      right=$REPLY
      top+="%F{$REPLY}$c1"
      bottom+="%F{$REPLY}$c2"
      sep+="%F{$REPLY}$c3"
    done
    print -P -- "$top%f"
    for r in "${rows[@]}"; do
      if [[ $r == -- ]]; then
        print -P -- "$sep%f"
      else
        _welcome_len "$r"
        if ((REPLY > inner - 2)); then
          _welcome_clip "$r" $((inner - 2))
          r=$REPLY
          REPLY=$((inner - 2))
        fi
        print -P -- "%F{$left}│%f $r${(l:inner - 2 - REPLY:: :)} %F{$right}│%f"
      fi
    done
    print -P -- "$bottom%f"
  fi
}

# Pack `key description` pairs into rows that fit the box. An empty description shows the key only.
_welcome_pack() {
  local line= k d
  local -i used=0 n
  while (($#)); do
    k=$1 d=$2
    shift 2
    n=${#k}
    [[ -n $d ]] && n+=$((${#d} + 1))
    if ((used && used + 2 + n > width - 2)); then
      rows+=("$line")
      line= used=0
    fi
    if ((used)); then
      line+="  "
      ((used += 2))
    fi
    line+="%F{$yellow}${k//\%/%%}%f"
    [[ -n $d ]] && line+=" %F{$dim}${d//\%/%%}%f"
    ((used += n))
  done
  [[ -n $line ]] && rows+=("$line")
}

# REPLY = display width of a prompt-escaped string. Counts characters, not wcwidth: every glyph
# used here is one column wide in a Nerd Font Mono terminal font, while zsh's wcwidth reports
# supplementary-plane icons as 0.
_welcome_len() {
  emulate -L zsh -o extended_glob
  local s=${1//\%[FK]\{[^\}]#\}/}
  s=${s//\%[fk]/}
  s=${s//\%\%/%}
  REPLY=${#s}
}

# REPLY = a prompt-escaped string cut to $2 display columns, the last one an ellipsis. Color
# escapes take no columns and are kept, so the colors up to the cut stay as they were.
_welcome_clip() {
  emulate -L zsh -o extended_glob
  local s=$1 out= token
  local -i room=$(($2 - 1))
  while [[ -n $s ]] && ((room > 0)); do
    if [[ $s == (#b)(%[FK]\{[^\}]#\}|%[fk])* ]]; then
      token=$match[1]
    elif [[ $s == %%* ]]; then
      token=%%
      ((room--))
    else
      token=${s[1]}
      ((room--))
    fi
    out+=$token
    s=${s:${#token}}
  done
  REPLY="$out…%f%k"
}

# REPLY = color `step` of `steps` along the line from color $1 to color $2 (#rrggbb).
_welcome_mix() {
  local a=${1#\#} b=${2#\#}
  local -i i=$3 n=$4
  local -i r=$(((16#${a:0:2} * (n - i) + 16#${b:0:2} * i) / n))
  local -i g=$(((16#${a:2:2} * (n - i) + 16#${b:2:2} * i) / n))
  local -i bl=$(((16#${a:4:2} * (n - i) + 16#${b:4:2} * i) / n))
  printf -v REPLY '#%02x%02x%02x' $r $g $bl
}

# REPLY = what changed since the previous release, e.g. "↑ 2 updated  + 1 new since v0.2.0".
_welcome_since() {
  local -a what=()
  ((updated)) && what+=("%F{$green}↑%f %F{$dim}$updated updated%f")
  ((added)) && what+=("%F{$green}+%f %F{$dim}$added new%f")
  ((updated + added)) || what+=("%F{$dim}no changes%f")
  REPLY="${(j:  :)what} %F{$dim}since v$since%f"
}

# REPLY = $1 cut to $2 characters (with an ellipsis), escaped for prompt expansion.
_welcome_trunc() {
  local s=$1
  ((${#s} > $2)) && s="${s[1,$2-1]}…"
  REPLY=${s//\%/%%}
}

# REPLY = a status flag: the name and a dot, green when $2 is 0 (ready), dim otherwise.
_welcome_flag() {
  if (($2 == 0)); then
    REPLY="%F{$fg}$1%f %F{$green}●%f"
  else
    REPLY="%F{$dim}$1 ○%f"
  fi
}

_welcome_complete() {
  _arguments '1:view:((tools\:"every pinned tool" keys\:"aliases and key bindings" help\:usage))' \
    '--plain[print without color or box]'
}
(($+functions[compdef])) && compdef _welcome_complete welcome
