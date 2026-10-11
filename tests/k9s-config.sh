#!/usr/bin/env bash
# Validate the seeded k9s config against k9s's own JSON schemas, for the k9s version
# pinned in toolchain/mise.toml. k9s itself silently ignores unknown keys, so this is
# the only thing that catches typos. Runs INSIDE the dev image (needs network for uvx).
# Usage: k9s-config.sh [config-dir]   (default: ~/.config/k9s)
set -euo pipefail

dir="${1:-$HOME/.config/k9s}"
ver="$(k9s version --short | awk '/^Version/ {print $2}')"
base="https://raw.githubusercontent.com/derailed/k9s/${ver}/internal/config/json/schemas"
check=(uvx --quiet check-jsonschema@0.33.3)

rc=0
for pair in config.yaml:k9s aliases.yaml:aliases hotkeys.yaml:hotkeys skins/one-dark.yaml:skin; do
  file="${pair%%:*}" schema="${pair##*:}"
  [[ -f "$dir/$file" ]] || continue
  if "${check[@]}" --schemafile "$base/$schema.json" "$dir/$file" >/dev/null 2>&1; then
    echo "ok   $file  (schema $schema.json @ $ver)"
  else
    echo "FAIL $file"
    "${check[@]}" --schemafile "$base/$schema.json" "$dir/$file" || true
    rc=1
  fi
done
exit "$rc"
