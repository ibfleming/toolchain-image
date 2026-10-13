#!/bin/bash
#
# Set up the dev image's shell environment on an Ubuntu or Debian machine,
# from a clone of this repository: the zsh config, starship, the zsh
# plugins at their pinned commits, the pinned tools (through mise, verified
# against the lock files), completions, k9s config, git defaults and the
# data `welcome` shows.
#
# Shared config is symlinked into the clone, so `git pull` updates it. Run
# again after a pull that changes tool versions; every step is idempotent.
#
# Usage: scripts/setup_host.sh   (as your normal user; it uses sudo)
# Needs: Ubuntu or Debian (apt), sudo, network access to GitHub and mise.

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly MISE_KEY_URL="https://mise.jdx.dev/gpg-key.pub"
readonly MISE_KEYRING="/etc/apt/keyrings/mise-archive-keyring.asc"
readonly MISE_APT_REPO="https://mise.jdx.dev/deb stable main"
readonly SHARE_DIR="/usr/local/share/toolchain"
readonly LIB_DIR="/usr/local/lib/toolchain"
readonly PLUGIN_DIR="/usr/local/share/zsh-plugins"
readonly RELEASE_DIR="/etc/toolchain"
# Packages the config and the tools rely on.
readonly -a PACKAGES=(
  zsh git curl jq gnupg ca-certificates less unzip xz-utils
)
# zsh plugins and their GitHub repositories. The Dockerfile pins each one's
# commit as ARG <NAME>_COMMIT (the name in capitals, "-" as "_").
readonly -a PLUGINS=(
  "zsh-autosuggestions zsh-users/zsh-autosuggestions"
  "zsh-syntax-highlighting zsh-users/zsh-syntax-highlighting"
  "zsh-completions zsh-users/zsh-completions"
  "fzf-tab Aloxaf/fzf-tab"
)

# shellcheck source=scripts/lib/log.sh
source "${REPO_DIR}/scripts/lib/log.sh"

#######################################
# Stop unless this is an apt-based system and the user is not root.
#######################################
check_system() {
  if ! command -v apt-get >/dev/null; then
    log::fatal "needs Ubuntu or Debian (apt-get not found)"
  fi
  if ((EUID == 0)); then
    log::fatal "run as your normal user; the script uses sudo where needed"
  fi
}

#######################################
# Install the base packages.
# Globals:
#   PACKAGES
#######################################
install_packages() {
  log::info "installing packages: ${PACKAGES[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y -qq "${PACKAGES[@]}" >/dev/null
}

#######################################
# Install mise from its signed apt repository.
# Globals:
#   MISE_KEY_URL, MISE_KEYRING, MISE_APT_REPO
#######################################
install_mise() {
  if command -v mise >/dev/null; then
    log::info "mise already installed ($(mise --version))"
    return 0
  fi
  log::info "installing mise from its apt repository"
  sudo install -d -m 0755 "${MISE_KEYRING%/*}"
  curl -fsSL "${MISE_KEY_URL}" | sudo tee "${MISE_KEYRING}" >/dev/null
  echo "deb [signed-by=${MISE_KEYRING}] ${MISE_APT_REPO}" \
    | sudo tee /etc/apt/sources.list.d/mise.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq mise >/dev/null
}

#######################################
# Install the pinned tools: both manifests as global mise config, and their
# locks merged into the one lock file mise uses for global config.
# MISE_LOCKED=1 makes mise refuse anything not in the lock, and verify each
# download against its locked checksum.
# Globals:
#   REPO_DIR
#   HOME
#######################################
install_tools() {
  local conf="${HOME}/.config/mise"
  log::info "installing the pinned tools (mise, locked)"
  mkdir -p "${conf}/conf.d"
  ln -sfn "${REPO_DIR}/toolchain/mise.toml" "${conf}/conf.d/10-ci.toml"
  ln -sfn "${REPO_DIR}/toolchain/dev/mise.toml" "${conf}/conf.d/20-dev.toml"
  {
    cat "${REPO_DIR}/toolchain/mise.lock"
    grep -vE '^(# @generated|lockfile_version)' \
      "${REPO_DIR}/toolchain/dev/mise.lock"
  } >"${conf}/mise.lock"
  MISE_LOCKED=1 mise install --yes
}

#######################################
# Link the shared config where the image keeps it.
# Globals:
#   REPO_DIR, SHARE_DIR, LIB_DIR
#######################################
link_shared_config() {
  log::info "linking the shared config into ${SHARE_DIR}"
  sudo install -d -m 0755 "${SHARE_DIR}" "${LIB_DIR%/*}"
  sudo ln -sfn "${REPO_DIR}/config/zsh" "${SHARE_DIR}/zsh"
  sudo ln -sfn "${REPO_DIR}/config/starship" "${SHARE_DIR}/starship"
  sudo ln -sfn "${REPO_DIR}/scripts/lib" "${LIB_DIR}"
}

#######################################
# Fetch one zsh plugin at a commit. A commit is content-addressed, so git
# verifies what it fetches.
# Globals:
#   PLUGIN_DIR
# Arguments:
#   Plugin name, GitHub repository, commit.
#######################################
fetch_plugin() {
  local name="$1"
  local repo="$2"
  local commit="$3"
  local dir="${PLUGIN_DIR}/${name}"
  sudo rm -rf "${dir}"
  sudo git init -q "${dir}"
  sudo git -C "${dir}" fetch -q --depth 1 "https://github.com/${repo}.git" \
    "${commit}"
  sudo git -C "${dir}" -c advice.detachedHead=false checkout -q "${commit}"
}

#######################################
# Fetch every zsh plugin at the commit the Dockerfile pins.
# Globals:
#   PLUGINS, REPO_DIR
#######################################
fetch_plugins() {
  local entry name repo arg commit
  for entry in "${PLUGINS[@]}"; do
    read -r name repo <<<"${entry}"
    arg="${name^^}"
    arg="${arg//-/_}"
    commit="$(sed -n "s/^ARG ${arg}_COMMIT=//p" "${REPO_DIR}/Dockerfile")"
    if [[ -z "${commit}" ]]; then
      log::fatal "no ${arg}_COMMIT in the Dockerfile"
    fi
    log::info "zsh plugin ${name} @ ${commit:0:12}"
    fetch_plugin "${name}" "${repo}" "${commit}"
  done
}

#######################################
# Write the shell startup files: ~/.zshenv puts mise's tools ahead of the
# system's, adds the generated completions, and turns off the system's own
# compinit (the config runs a cached one); ~/.zshrc loads the shared config.
# Also copies the k9s config, if there is none yet.
# Globals:
#   REPO_DIR
#   HOME
#######################################
write_shell_startup() {
  log::info "writing ~/.zshenv and ~/.zshrc"
  cat >"${HOME}/.zshenv" <<'EOF'
# Written by toolchain-image's scripts/setup_host.sh.
# Tools pinned by toolchain-image (mise), ahead of the system's.
path=("${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims" $path)
fpath=("${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions" $fpath)
skip_global_compinit=1
EOF
  cp "${REPO_DIR}/config/home/.zshrc" "${HOME}/.zshrc"
  mkdir -p "${HOME}/.config"
  cp -r --update=none "${REPO_DIR}/config/home/.config/k9s" \
    "${HOME}/.config/"
}

#######################################
# Generate the tools' zsh completions into the user's data directory.
# Globals:
#   REPO_DIR
#   HOME
#######################################
generate_completions() {
  PATH="${HOME}/.local/share/mise/shims:${PATH}" \
    TOOLCHAIN_LIB_DIR="${REPO_DIR}/scripts/lib" \
    "${REPO_DIR}/scripts/gen_zsh_completions.sh" \
    "${HOME}/.local/share/zsh/site-functions"
}

#######################################
# Include the image's git defaults (delta pager, zdiff3, ...) from the
# user's git config, rather than copying them.
# Globals:
#   REPO_DIR
#######################################
configure_git() {
  log::info "including the git defaults in ~/.gitconfig"
  git config --global include.path "${REPO_DIR}/config/git/gitconfig"
}

#######################################
# Write what `welcome` shows: the pinned tool versions, and the checkout's
# version and commit.
# Globals:
#   REPO_DIR, RELEASE_DIR
#   HOME
#######################################
write_welcome_data() {
  local described revision
  described="$(git -C "${REPO_DIR}" describe --tags 2>/dev/null || true)"
  revision="$(git -C "${REPO_DIR}" rev-parse HEAD)"
  log::info "writing ${RELEASE_DIR}/{versions,release}"
  sudo install -d -m 0755 "${RELEASE_DIR}"
  PATH="${HOME}/.local/share/mise/shims:${PATH}" \
    "${REPO_DIR}/scripts/print_versions.sh" \
    | sudo tee "${RELEASE_DIR}/versions" >/dev/null
  printf '%s\n' "TOOLCHAIN_VERSION=${described#v}" \
    "TOOLCHAIN_REVISION=${revision}" \
    | sudo tee "${RELEASE_DIR}/release" >/dev/null
}

#######################################
# Make sure the system has a UTF-8 locale: the prompt and `welcome` use
# Nerd Font glyphs. Ubuntu installs normally have one; minimal and
# container images may not.
#######################################
ensure_utf8_locale() {
  if [[ -s /etc/default/locale ]] \
    && grep -qiE 'utf-?8' /etc/default/locale; then
    return 0
  fi
  log::info "setting LANG=C.UTF-8 in /etc/default/locale"
  echo 'LANG=C.UTF-8' | sudo tee /etc/default/locale >/dev/null
}

#######################################
# Make zsh the user's login shell.
#######################################
set_login_shell() {
  local zsh_path user
  zsh_path="$(command -v zsh)"
  user="$(id -un)"
  if [[ "$(getent passwd "${user}" | cut -d: -f7)" != "${zsh_path}" ]]; then
    log::info "setting ${zsh_path} as the login shell of ${user}"
    sudo chsh -s "${zsh_path}" "${user}"
  fi
}

main() {
  check_system
  install_packages
  install_mise
  install_tools
  link_shared_config
  fetch_plugins
  write_shell_startup
  generate_completions
  configure_git
  write_welcome_data
  ensure_utf8_locale
  set_login_shell
  log::ok "done: open a new terminal (with a Nerd Font) to start zsh"
}

main "$@"
