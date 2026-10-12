#!/usr/bin/env bash
# Print the previous release as bake variables, for the "what changed" marks in the dev image's
# `welcome` (baked into /etc/toolchain/previous):
#   PREVIOUS_VERSION=X.Y.Z
#   PREVIOUS_TOOLS=tool=version tool=version ...
# The previous release is the highest vX.Y.Z tag below version $1 (default: the highest tag). Its
# toolchain comes from that GitHub Release's notes (the "## Toolchain" table), so no image is
# pulled. Prints nothing when there is no previous release or its notes can't be read; the image
# then shows no marks. Needs gh with access to the repository (GH_TOKEN in CI).
set -euo pipefail
current="${1:-}"
semver='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

previous=
while read -r tag; do
  [[ $tag =~ $semver ]] || continue
  if [[ -z $current ]]; then
    previous=$tag
    break
  fi
  # The newest tag that sorts below the current version (and isn't it).
  if [[ ${tag#v} != "$current" && "$(printf '%s\n' "${tag#v}" "$current" | sort -V | head -n1)" == "${tag#v}" ]]; then
    previous=$tag
    break
  fi
done < <(git tag --list 'v*.*.*' --sort=-v:refname)
[[ -n $previous ]] || exit 0

notes="$(gh release view "$previous" --json body --jq .body 2>/dev/null | tr -d '\r')" || exit 0
# shellcheck disable=SC2016 # the backticks are literal Markdown
tools="$(
  awk '/^## Toolchain/ { on = 1; next } /^## / { on = 0 } on && /^\| `/' <<<"$notes" \
    | sed -E 's/^\| `([^`]+)` \| ([^ |]+) \|.*/\1=\2/' \
    | paste -sd ' ' -
)"
[[ -n $tools ]] || exit 0
printf 'PREVIOUS_VERSION=%s\nPREVIOUS_TOOLS=%s\n' "${previous#v}" "$tools"
