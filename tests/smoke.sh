#!/bin/bash
#
# Smoke test, run INSIDE an image: for every tool in print-versions, run the
# binary found on PATH and check that it reports the manifest's version.
# Proves the symlinked binaries are the pinned ones. A new manifest tool
# without a probe here fails the test on purpose.

set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "${TOOLCHAIN_LIB_DIR:-/usr/local/lib/toolchain}/log.sh"

#######################################
# Run a tool's version command.
# Arguments:
#   Tool name as print-versions reports it.
# Outputs:
#   The command's output; for a tool without a probe, a hint (the caller
#   shows it as the result).
# Returns:
#   The command's status; 2 if the tool has no probe.
#######################################
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
    *lazydocker) lazydocker --version ;;
    aqua:cli/cli) gh --version ;;
    *kubens) kubens --version ;;
    aqua:docker/buildx) docker buildx version ;;
    aqua:docker/compose) docker compose version ;;
    *kubectx) kubectx --version ;;
    *neovim) nvim --version ;;
    *pnpm) pnpm --version ;;
    *)
      echo "no probe for '$1': add one to tests/smoke.sh"
      return 2
      ;;
  esac
}

main() {
  local tool version out line
  local -i failed=0
  while IFS='=' read -r tool version; do
    if out="$(probe "${tool}" 2>&1)" \
      && grep -qF "${version}" <<<"${out}"; then
      printf -v line '%-40s %s' "${tool}" "${version}"
      log::ok "${line}"
    else
      printf -v line '%-40s want %s, got: %s' "${tool}" "${version}" \
        "${out%%$'\n'*}"
      log::error "${line}"
      failed=1
    fi
  done < <(print-versions)
  return "${failed}"
}

main "$@"
