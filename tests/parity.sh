#!/bin/bash
#
# Parity test, run on the host:
#   1. the ci toolchain equals the manifest (toolchain/mise.toml [tools]);
#   2. ci is a subset of dev, with identical versions.
#
# Usage: tests/parity.sh <ci image> <dev image>

set -euo pipefail

readonly REPO_DIR="${BASH_SOURCE[0]%/*}/.."
# The [tools] table of a mise.toml as sorted `tool=version` lines.
# shellcheck disable=SC2016 # awk fields, not shell variables
readonly AWK_TOOLS='
  /^\[/ { in_tools = ($0 == "[tools]"); next }
  in_tools && /=/ && !/^[[:space:]]*#/ {
    split($0, kv, "=")
    k = kv[1]; v = kv[2]
    gsub(/[[:space:]"]/, "", k); gsub(/[[:space:]"]/, "", v)
    print k "=" v
  }'

# shellcheck source=scripts/lib/log.sh
source "${REPO_DIR}/scripts/lib/log.sh"

main() {
  local ci_image="${1:-}"
  local dev_image="${2:-}"
  local manifest ci dev missing count tool
  local -i failed=0
  if [[ -z "${ci_image}" || -z "${dev_image}" ]]; then
    log::fatal "usage: tests/parity.sh <ci image> <dev image>"
  fi
  manifest="$(awk "${AWK_TOOLS}" "${REPO_DIR}/toolchain/mise.toml" | sort)"
  ci="$(docker run --rm "${ci_image}" print-versions)"
  dev="$(docker run --rm "${dev_image}" print-versions)"

  if ! diff -u <(echo "${manifest}") <(echo "${ci}") \
    --label manifest --label ci; then
    log::error "the ci toolchain does not match toolchain/mise.toml"
    failed=1
  fi
  missing="$(comm -23 <(echo "${ci}") <(echo "${dev}"))"
  if [[ -n "${missing}" ]]; then
    log::error "dev is missing, or differs from ci on:"
    while IFS= read -r tool; do
      log::error "  ${tool}"
    done <<<"${missing}"
    failed=1
  fi
  if ((failed == 0)); then
    count="$(wc -l <<<"${ci}")"
    log::ok "${count} tools; manifest == ci, and ci is a subset of dev"
  fi
  return "${failed}"
}

main "$@"
