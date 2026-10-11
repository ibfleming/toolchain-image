#!/usr/bin/env bash
# Host-side parity test:
#   1. ci toolchain == manifest (toolchain/mise.toml [tools])
#   2. ci ⊆ dev with identical versions
# Usage: tests/parity.sh <ci-image> <dev-image>
set -euo pipefail
ci_img="${1:?ci image}"
dev_img="${2:?dev image}"
here="$(cd "$(dirname "$0")/.." && pwd)"

manifest="$(awk '
  /^\[/ { in_tools = ($0 == "[tools]"); next }
  in_tools && /=/ && !/^[[:space:]]*#/ {
    split($0, kv, "=")
    k = kv[1]; v = kv[2]
    gsub(/[[:space:]"]/, "", k); gsub(/[[:space:]"]/, "", v)
    print k "=" v
  }' "$here/toolchain/mise.toml" | sort)"
ci="$(docker run --rm "$ci_img" print-versions)"
dev="$(docker run --rm "$dev_img" print-versions)"

rc=0
if ! diff -u <(echo "$manifest") <(echo "$ci") --label manifest --label ci; then
  echo "parity: ci toolchain does not match toolchain/mise.toml" >&2
  rc=1
fi
missing="$(comm -23 <(echo "$ci") <(echo "$dev"))"
if [[ -n "$missing" ]]; then
  echo "parity: dev is missing or differs from ci on:" >&2
  echo "$missing" >&2
  rc=1
fi
[[ $rc -eq 0 ]] && echo "parity: ok ($(wc -l <<<"$ci") tools; manifest == ci ⊆ dev)"
exit "$rc"
