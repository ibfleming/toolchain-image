#!/bin/bash
#
# Decide the version of a release workflow run, and print it as GitHub step
# outputs:
#   version=X.Y.Z
#   tag=vX.Y.Z
#   new_tag=true|false
#
# - A tag push (vX.Y.Z) releases that version; the tag already exists.
# - A scheduled or manual run (main only) releases the next version after
#   the highest vX.Y.Z tag, from the Conventional Commits since it: a
#   breaking change bumps major (minor below 1.0.0), a `feat` minor, and
#   anything else, or nothing (a rebuild with fresh OS packages), patch. The
#   workflow creates the tag at the end, only if the run succeeds.
#
# STDOUT is the data ($GITHUB_OUTPUT); messages go to STDERR.

set -euo pipefail

readonly SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly BREAKING_TITLE_RE='^[a-z]+(\([^)]*\))?!:'
readonly BREAKING_FOOTER_RE='^BREAKING[ -]CHANGE:'
readonly FEAT_TITLE_RE='^feat(\([^)]*\))?:'

# shellcheck source=image/lib/log.sh
source "${BASH_SOURCE[0]%/*}/../image/lib/log.sh"

#######################################
# Print the highest vX.Y.Z tag, or nothing.
# Outputs:
#   The tag to STDOUT.
#######################################
latest_tag() {
  git tag --list 'v*.*.*' --sort=-v:refname \
    | grep -E "${SEMVER_RE}" \
    | head -n1 \
    || true
}

#######################################
# Print the bump the commits since a tag call for: major, minor or patch.
# Types come from commit titles only: a squash body lists the branch's
# commits, which can include a `feat` line in what is overall a fix.
# Breaking-change footers come from the bodies.
# Arguments:
#   The tag to compare against.
# Outputs:
#   The bump to STDOUT.
#######################################
bump_since() {
  local since="$1"
  local subjects bodies
  subjects="$(git log --format=%s "${since}..HEAD")"
  bodies="$(git log --format=%b "${since}..HEAD")"
  if grep -qE "${BREAKING_TITLE_RE}" <<<"${subjects}" \
    || grep -qE "${BREAKING_FOOTER_RE}" <<<"${bodies}"; then
    echo "major"
  elif grep -qE "${FEAT_TITLE_RE}" <<<"${subjects}"; then
    echo "minor"
  else
    echo "patch"
  fi
}

#######################################
# Print the next tag after the latest one, from the commits since it.
# Outputs:
#   The tag to STDOUT; the reasoning to STDERR.
# Returns:
#   0 on success; exits 1 when there is no vX.Y.Z tag yet.
#######################################
next_tag() {
  local latest bump count tag
  local -i major minor patch
  latest="$(latest_tag)"
  if [[ -z "${latest}" ]]; then
    log::fatal "no vX.Y.Z tag yet; push one (e.g. v0.1.0) first"
  fi
  [[ "${latest}" =~ ${SEMVER_RE} ]]
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  bump="$(bump_since "${latest}")"
  if [[ "${bump}" == "major" && "${major}" -eq 0 ]]; then
    bump="minor"
  fi
  case "${bump}" in
    major) tag="v$((major + 1)).0.0" ;;
    minor) tag="v${major}.$((minor + 1)).0" ;;
    patch) tag="v${major}.${minor}.$((patch + 1))" ;;
  esac
  count="$(git rev-list --count "${latest}..HEAD")"
  log::info "${latest} -> ${tag} (${bump} bump," \
    "${count} commit(s) since ${latest})"
  echo "${tag}"
}

main() {
  local tag new_tag
  if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    tag="${GITHUB_REF_NAME:?}"
    if [[ ! "${tag}" =~ ${SEMVER_RE} ]]; then
      log::fatal "tag '${tag}' is not vX.Y.Z"
    fi
    new_tag="false"
  else
    # A scheduled or manual release is built from main, never a branch.
    # (Unset outside Actions: a local dry run.)
    if [[ "${GITHUB_REF:-refs/heads/main}" != "refs/heads/main" ]]; then
      log::fatal "releases run from main or a vX.Y.Z tag, not ${GITHUB_REF}"
    fi
    tag="$(next_tag)"
    new_tag="true"
  fi
  printf 'version=%s\ntag=%s\nnew_tag=%s\n' "${tag#v}" "${tag}" "${new_tag}"
}

main "$@"
