#!/usr/bin/env bash
# Render the README screenshots of the dev image's `welcome` views into docs/assets/ from the
# local dev image (`make build` first). Everything machine-specific comes from fixtures (a sample
# repository, git identity, SSH agent, kube context, Claude Code and GitHub CLI sign-in), so the
# pictures are the same on every machine and show nobody's real setup. The version shown is the
# next minor after the latest release, with that release's tools as "previous" (needs gh) when
# available.
#
# Usage: FONT=/path/to/NerdFontMono.ttf [FONT_FAMILY='CaskaydiaCove NFM'] scripts/screenshots.sh
# FONT must be a Nerd Font *Mono* (single-width icons), e.g. CaskaydiaCove Nerd Font Mono.
set -euo pipefail
: "${FONT:?set FONT to a Nerd Font Mono .ttf file}"
FONT_FAMILY="${FONT_FAMILY:-CaskaydiaCove NFM}"
IMAGE="${DEV_IMG:-toolchain/dev:local}"
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out" "$work/sample/.git"
chmod 0777 "$work/out" # written by the image's vscode user

# Build metadata: next minor after the latest release, compared against that release.
previous="$(scripts/previous-tools.sh 2>/dev/null || true)"
prev_version="$(sed -n 's/^PREVIOUS_VERSION=//p' <<<"$previous")"
IFS=. read -r major minor _ <<<"${prev_version:-0.0.0}"
{
  echo "TOOLCHAIN_VERSION=$major.$((minor + 1)).0"
  echo "TOOLCHAIN_REVISION=$(git rev-parse HEAD)"
  echo "TOOLCHAIN_CREATED=$(date -u +%F)"
  echo "TOOLCHAIN_PREVIOUS=$prev_version"
} >"$work/release"
sed -n 's/^PREVIOUS_TOOLS=//p' <<<"$previous" | tr ' ' '\n' | sed '/^$/d' >"$work/previous"

# Fixtures for the project and status rows.
echo 'ref: refs/heads/main' >"$work/sample/.git/HEAD"
printf '[user]\n  name = Dev\n  email = dev@example.com\n' >"$work/gitconfig"
printf 'apiVersion: v1\nkind: Config\ncurrent-context: dev-cluster\n' >"$work/kubeconfig"
echo '{}' >"$work/credentials.json"
printf 'github.com:\n  user: dev\n' >"$work/gh-hosts.yml"

prompt=$'\e[38;2;198;120;221m❯\e[0m'
docker run --rm -t -u vscode -e COLUMNS=100 -e SSH_AUTH_SOCK=/tmp/agent.sock \
  -v "$work/release:/etc/toolchain/release:ro" \
  -v "$work/previous:/etc/toolchain/previous:ro" \
  -v "$work/sample:/workspaces/my-service:ro" -w /workspaces/my-service \
  -v "$work/gitconfig:/home/vscode/.gitconfig:ro" \
  -v "$work/kubeconfig:/home/vscode/.kube/config:ro" \
  -v "$work/credentials.json:/home/vscode/.claude/.credentials.json:ro" \
  -v "$work/gh-hosts.yml:/home/vscode/.config/gh/hosts.yml:ro" \
  -v "$work/out:/out" -e PROMPT_MARK="$prompt" \
  "$IMAGE" zsh -i -c '
    python3 -c "import socket; socket.socket(socket.AF_UNIX).bind(\"/tmp/agent.sock\")"
    welcome >/out/welcome.ansi
    for view in tools keys; do
      { print -r -- "$PROMPT_MARK welcome $view"; welcome $view; } >/out/welcome-$view.ansi
    done' >/dev/null

# Render with the dev image's Node and a pinned resvg; the font is mounted read-only.
cp scripts/screenshots/render.js "$work/out/"
docker run --rm -u vscode -e NPM_CONFIG_UPDATE_NOTIFIER=false -e NPM_CONFIG_FUND=false \
  -v "$work/out:/out" -v "$(realpath "$FONT"):/font.ttf:ro" -w /out "$IMAGE" bash -c '
    npm install --silent --no-save --no-package-lock @resvg/resvg-js@2.6.2 >/dev/null
    for f in welcome welcome-tools welcome-keys; do
      node render.js "$f.ansi" "$f.png" /font.ttf "$1"
    done' _ "$FONT_FAMILY"
cp "$work"/out/welcome*.png docs/assets/
