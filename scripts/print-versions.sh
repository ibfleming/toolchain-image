#!/usr/bin/env bash
# Print the image's pinned toolchain as sorted `tool=version` lines: the ci manifest,
# plus the dev-only manifest when present (dev image). Used by the ci ⊆ dev parity
# test and the smoke test.
set -euo pipefail
cd /

list() {
  mise ls --global --json \
    | jq -r 'to_entries[] | .key as $t | .value[] | select(.installed) | "\($t)=\(.version)"'
}

{
  list
  if [[ -f /etc/mise/dev/mise.toml ]]; then
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/dev/mise.toml list
  fi
  # Claude Code is pinned in the Dockerfile (not mise); report it alongside.
  if [[ -x /usr/local/bin/claude ]]; then
    echo "claude-code=$(/usr/local/bin/claude --version | awk '{print $1}')"
  fi
} | sort -u # mise also reads /etc/mise as system config, so ci tools can repeat
