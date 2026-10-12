#!/usr/bin/env bash
# Decide the release version for a release workflow run and print GitHub step outputs:
#   version=X.Y.Z  tag=vX.Y.Z  new_tag=true|false
# - tag push (vX.Y.Z): that version; the tag already exists.
# - schedule / manual run (main only): the next version after the highest vX.Y.Z tag, from the
#   Conventional Commits since it: a breaking change bumps major, a `feat` minor, anything else
#   (or nothing: a rebuild with fresh OS packages) patch. Below 1.0.0, breaking changes bump
#   minor. The tag is created at the end of the run, only if it succeeds.
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
  # A scheduled or manual release is built from main, never from another branch.
  [[ -z ${GITHUB_REF:-} || $GITHUB_REF == refs/heads/main ]] || {
    echo "release-version: releases run from main or a vX.Y.Z tag, not $GITHUB_REF" >&2
    exit 1
  }
  latest="$(git tag --list 'v*.*.*' --sort=-v:refname | grep -E "$semver" | head -n1 || true)"
  [[ -n $latest ]] || {
    echo "release-version: no vX.Y.Z tag yet; push one (e.g. v0.1.0) first" >&2
    exit 1
  }
  [[ $latest =~ $semver ]]
  major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"

  # Commit titles carry the type (`feat`, `type!`); breaking-change footers are in the bodies.
  # Bodies are not searched for types: a squash body lists the branch's commits, which can
  # include a `feat` line in what is overall a fix.
  subjects="$(git log --format=%s "$latest..HEAD")"
  bodies="$(git log --format=%b "$latest..HEAD")"
  if grep -qE '^[a-z]+(\([^)]*\))?!:' <<<"$subjects" || grep -qE '^BREAKING[ -]CHANGE:' <<<"$bodies"; then
    bump='major'
  elif grep -qE '^feat(\([^)]*\))?:' <<<"$subjects"; then
    bump='minor'
  else
    bump='patch'
  fi
  [[ $bump == major && $major == 0 ]] && bump='minor'

  case $bump in
    major) tag="v$((major + 1)).0.0" ;;
    minor) tag="v$major.$((minor + 1)).0" ;;
    patch) tag="v$major.$minor.$((patch + 1))" ;;
  esac
  count="$(git rev-list --count "$latest..HEAD")"
  echo "release-version: $latest -> $tag ($bump bump, $count commit(s) since $latest)" >&2
  new_tag=true
fi

printf 'version=%s\ntag=%s\nnew_tag=%s\n' "${tag#v}" "$tag" "$new_tag"
