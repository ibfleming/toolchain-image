# Prompt: starship when available, a plain fallback otherwise.
# A personal ~/.config/starship.toml wins; otherwise the image's shared config is used.

if (($+commands[starship])); then
  if [[ -z ${STARSHIP_CONFIG:-} && ! -r "$XDG_CONFIG_HOME/starship.toml" ]]; then
    export STARSHIP_CONFIG=/usr/local/share/toolchain/starship/starship.toml
  fi
  eval "$(starship init zsh)"
else
  PROMPT='%F{blue}%~%f %(?.%F{green}.%F{red})❯%f '
fi
