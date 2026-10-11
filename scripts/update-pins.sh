#!/usr/bin/env bash
# Recompute the checksums pinned next to version ARGs in the Dockerfile, for the versions
# currently set there. Renovate bumps the *_VERSION ARGs but cannot compute checksums, so
# after a bump CI fails on the old checksum; run `make pins` on the PR branch and push.
#   MISE_VERSION                  -> MISE_SHA256_AMD64 (SHASUMS256.txt, cross-checked with
#                                    the GitHub release asset digest)
#   <NAME>_VERSION + renovate     -> <NAME>_SHA256 (GitHub tag tarball, github-tags only)
set -euo pipefail
cd "$(dirname "$0")/.."
df=Dockerfile

arg() { sed -nE "s/^ARG $1=(.*)$/\1/p" "$df"; }
set_arg() {
  local name="$1" value="$2" old
  old="$(arg "$name")"
  if [[ $old != "$value" ]]; then
    sed -i -E "s|^ARG $name=.*$|ARG $name=$value|" "$df"
    echo "pins: $name ${old:0:12}... -> ${value:0:12}..."
  else
    echo "pins: $name unchanged"
  fi
}

# mise
v="$(arg MISE_VERSION)"
asset="mise-v$v-linux-x64"
sum="$(curl -fsSL "https://github.com/jdx/mise/releases/download/v$v/SHASUMS256.txt" \
  | awk -v a="./$asset" '$2 == a {print $1}')"
[[ $sum =~ ^[0-9a-f]{64}$ ]] || {
  echo "pins: no checksum for $asset" >&2
  exit 1
}
gh_digest="$(scripts/github-api.sh "repos/jdx/mise/releases/tags/v$v" \
  | jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .digest // empty')"
if [[ -n $gh_digest && $gh_digest != "sha256:$sum" ]]; then
  echo "pins: $asset checksum mismatch between SHASUMS256.txt and GitHub asset digest" >&2
  exit 1
fi
set_arg MISE_SHA256_AMD64 "$sum"

# GitHub tag tarballs annotated with `# renovate: datasource=github-tags depName=<owner/repo>`
while read -r repo name; do
  ref="$(arg "${name}_VERSION")"
  sum="$(curl -fsSL "https://github.com/$repo/archive/refs/tags/$ref.tar.gz" | sha256sum | cut -d' ' -f1)"
  set_arg "${name}_SHA256" "$sum"
done < <(awk '
  /^# renovate: datasource=github-tags depName=/ { split($4, d, "="); repo = d[2]; next }
  repo != "" && /^ARG [A-Z0-9_]+_VERSION=/ { n = $2; sub(/_VERSION=.*/, "", n); print repo, n; repo = "" }
' "$df")
