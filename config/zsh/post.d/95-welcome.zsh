# Greet interactive terminals: once per container start by default.
#   TOOLCHAIN_WELCOME=once (default) | always | off   (or skip post.d/95-welcome)
# Never in non-interactive shells (`zsh -c`, VS Code tasks) or when stdout isn't a terminal.
if [[ -o interactive && -t 1 && -z ${ZSH_EXECUTION_STRING:-} ]] && (($+functions[welcome])); then
  case ${TOOLCHAIN_WELCOME:-once} in
    off) ;;
    always) welcome ;;
    *)
      # PID 1's start time identifies this container start (resets on restart/rebuild).
      _tc_welcome_mark="/tmp/.toolchain-welcome-${UID}-${${(s: :)${"$(</proc/1/stat)"#*) }}[20]:-0}"
      if [[ ! -e $_tc_welcome_mark ]]; then
        welcome
        : >|"$_tc_welcome_mark"
      fi
      unset _tc_welcome_mark
      ;;
  esac
fi
