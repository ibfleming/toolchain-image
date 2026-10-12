#!/usr/bin/env bash
# Runs INSIDE an image. For every tool in print-versions, execute the binary found on
# PATH and check it reports the manifest's version. Proves the symlinked binaries are
# the pinned ones. A new manifest tool without a probe here fails the test on purpose.
set -euo pipefail

probe() {
  case "$1" in
    *opentofu) tofu version ;;
    *kubectl) kubectl version --client ;;
    *helm) helm version --short ;;
    *k9s) k9s version --short ;;
    python)
      python3 --version
      python --version
      ;;
    *ruff) ruff --version ;;
    *uv) uv --version ;;
    go) go version ;;
    node)
      node --version
      npm --version >/dev/null
      ;;
    *CMake) cmake --version ;;
    *ninja) ninja --version ;;
    # dev-only tools
    *starship) starship --version ;;
    *fzf) fzf --version ;;
    *zoxide) zoxide --version ;;
    *vivid) vivid --version ;;
    *eza) eza --version ;;
    *bat) bat --version ;;
    *fd) fd --version ;;
    *ripgrep) rg --version ;;
    *delta) delta --version ;;
    *lazygit) lazygit --version ;;
    aqua:cli/cli) gh --version ;;
    *kubens) kubens --version ;;
    aqua:docker/buildx) docker buildx version ;;
    aqua:docker/compose) docker compose version ;;
    *kubectx) kubectx --version ;;
    *neovim) nvim --version ;;
    claude-code) claude --version ;;
    *)
      echo "smoke: no probe for '$1' - add one to tests/smoke.sh" >&2
      return 2
      ;;
  esac
}

fail=0
while IFS='=' read -r tool version; do
  if out="$(probe "$tool" 2>&1)" && grep -qF "$version" <<<"$out"; then
    printf 'ok   %-40s %s\n' "$tool" "$version"
  else
    printf 'FAIL %-40s want %s, got: %s\n' "$tool" "$version" "$(head -1 <<<"$out")"
    fail=1
  fi
done < <(print-versions)
exit "$fail"
