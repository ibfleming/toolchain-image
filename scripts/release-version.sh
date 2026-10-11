#!/usr/bin/env bash
# Decide the release version for a release workflow run and print GitHub step outputs:
#   version=X.Y.Z  tag=vX.Y.Z  new_tag=true|false
# - tag push (vX.Y.Z): that version; the tag already exists.
# - schedule / manual run: next patch after the highest vX.Y.Z tag (a rebuild with fresh
#   OS packages is a patch release); the tag is created at the end, only if the run succeeds.
set -euo pipefail
semver='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ ${GITHUB_REF_TYPE:-} == tag ]]; then
  tag="${GITHUB_REF_NAME:?}"
  [[ $tag =~ $semver ]] || {
    echo "release-version: tag '$tag' is not vX.Y.Z" >&2
    exit 1
  }
  new_tag=false
else
  latest="$(git tag --list 'v*.*.*' --sort=-v:refname | grep -E "$semver" | head -n1 || true)"
  [[ -n $latest ]] || {
    echo "release-version: no vX.Y.Z tag yet; push one (e.g. v0.1.0) first" >&2
    exit 1
  }
  [[ $latest =~ $semver ]]
  tag="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  new_tag=true
fi

printf 'version=%s\ntag=%s\nnew_tag=%s\n' "${tag#v}" "$tag" "$new_tag"
