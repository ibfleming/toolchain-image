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
} | sort -u # mise also reads /etc/mise as system config, so ci tools can repeat
