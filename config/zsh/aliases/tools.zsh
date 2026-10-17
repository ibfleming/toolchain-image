# Toolchain shortcuts.

if (($+commands[tofu])); then
  alias tf='tofu' tfi='tofu init' tfp='tofu plan' tfa='tofu apply'
  alias tfv='tofu validate' tff='tofu fmt -recursive'
fi
(($+commands[uv])) && alias uvr='uv run' uvs='uv sync'
(($+commands[cmake])) && alias cmb='cmake -S . -B build -G Ninja && cmake --build build'
(($+commands[lazydocker])) && alias lzd='lazydocker'
alias versions='print-versions'
