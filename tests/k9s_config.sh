#!/bin/bash
#
# Validate the seeded k9s config against k9s's own JSON schemas, for the k9s
# version in the image. k9s silently ignores unknown keys, so this is the
# only thing that catches typos. Runs INSIDE the dev image (needs network
# for uvx).
#
# Usage: k9s_config.sh [config dir]  (default: ~/.config/k9s)

set -euo pipefail

readonly SCHEMA_BASE="https://raw.githubusercontent.com/derailed/k9s"
readonly SCHEMA_DIR="internal/config/json/schemas"
# Config file and the schema that describes it.
readonly -a FILES=(
  config.yaml:k9s
  aliases.yaml:aliases
  hotkeys.yaml:hotkeys
  skins/one-dark.yaml:skin
)
readonly -a CHECK=(uvx --quiet check-jsonschema@0.33.3)

# shellcheck source=image/lib/log.sh
source "${TOOLCHAIN_LIB_DIR:-/usr/local/lib/toolchain}/log.sh"

#######################################
# Validate one file against a k9s schema.
# Globals:
#   CHECK
# Arguments:
#   Schema URL, config file path, name shown in the result, k9s version.
# Outputs:
#   The result to STDERR; on failure, the validator's report.
# Returns:
#   0 if valid, 1 otherwise.
#######################################
validate() {
  local schema="$1"
  local file="$2"
  local name="$3"
  local version="$4"
  if "${CHECK[@]}" --schemafile "${schema}" "${file}" >/dev/null 2>&1; then
    log::ok "${name}  (schema ${schema##*/schemas/} @ ${version})"
    return 0
  fi
  log::error "${name} does not match ${schema}"
  "${CHECK[@]}" --schemafile "${schema}" "${file}" >&2 || true
  return 1
}

main() {
  local dir="${1:-${HOME}/.config/k9s}"
  local version pair file schema
  local -i failed=0
  version="$(k9s version --short | awk '/^Version/ {print $2}')"
  for pair in "${FILES[@]}"; do
    file="${pair%%:*}"
    schema="${pair##*:}"
    [[ -f "${dir}/${file}" ]] || continue
    validate "${SCHEMA_BASE}/${version}/${SCHEMA_DIR}/${schema}.json" \
      "${dir}/${file}" "${file}" "${version}" || failed=1
  done
  return "${failed}"
}

main "$@"
