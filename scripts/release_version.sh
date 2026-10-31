#!/bin/bash
#
# Decide the version of a release workflow run, and print it as GitHub step
# outputs:
#   version=X.Y.Z
#   tag=vX.Y.Z
#   new_tag=true|false
#
# - A release (main only) is the next version after the highest vX.Y.Z tag
#   (v0.1.0 when there is none),
#   from the Conventional Commits since it: a breaking change bumps major
#   (minor below 1.0.0), a `feat` minor, and anything else, or nothing (a
#   rebuild with fresh OS packages), patch. RELEASE_BUMP=patch|minor|major
#   overrides that (a manual release's input; `auto` or unset keeps it). The
#   workflow creates the tag at the end, only if the run succeeds; tags are
#   never pushed by hand.
# - Except when an earlier run already pushed that tag but failed before
#   publishing its GitHub Release (a re-run): if the highest tag points at
#   this commit and has no GitHub Release, the run releases it again
#   (new_tag=false), instead of skipping to the next version. Needs gh, and
#   GH_TOKEN in CI.
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
# Breaking-change footers come from the bodies. RELEASE_BUMP, when set to
# patch, minor or major, decides instead.
# Globals:
#   RELEASE_BUMP
# Arguments:
#   The tag to compare against.
# Outputs:
#   The bump to STDOUT.
#######################################
# Print the highest vX.Y.Z tag if it points at HEAD and has no GitHub
# Release, or nothing. Any other answer from gh than "not found" (network,
# authentication) stops the run rather than risk releasing twice.
# Outputs:
#   The tag to STDOUT.
#######################################
pending_tag() {
  local latest err
  latest="$(latest_tag)"
  if [[ -z "${latest}" ]] \
    || [[ "$(git rev-list -n 1 "${latest}")" != "$(git rev-parse HEAD)" ]]; then
    return 0
  fi
  if err="$(gh release view "${latest}" --json tagName 2>&1 >/dev/null)"; then
    return 0
  fi
  if [[ "${err}" == *"not found"* ]]; then
    echo "${latest}"
    return 0
  fi
  log::fatal "can't tell whether ${latest} has a GitHub Release: ${err}"
}

#######################################
bump_since() {
  local since="$1"
  local subjects bodies
  if [[ "${RELEASE_BUMP:-auto}" != "auto" ]]; then
    echo "${RELEASE_BUMP}"
    return 0
  fi
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
#   The tag to STDOUT (v0.1.0 when there is no vX.Y.Z tag yet); the
#   reasoning to STDERR.
#######################################
next_tag() {
  local latest bump count tag
  local -i major minor patch
  latest="$(latest_tag)"
  if [[ -z "${latest}" ]]; then
    log::info "no vX.Y.Z tag yet: the first release is v0.1.0"
    echo "v0.1.0"
    return 0
  fi
  [[ "${latest}" =~ ${SEMVER_RE} ]]
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  bump="$(bump_since "${latest}")"
  # Below 1.0.0, a breaking change is a minor bump; asking for major is 1.0.0.
  if [[ "${bump}" == "major" && "${major}" -eq 0 &&
    "${RELEASE_BUMP:-auto}" == "auto" ]]; then
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
  case "${RELEASE_BUMP:-auto}" in
    auto | patch | minor | major) ;;
    *) log::fatal "RELEASE_BUMP must be auto, patch, minor or major" ;;
  esac
  # A release is built from main, never a branch or a tag. (Unset outside
  # Actions: a local dry run.)
  if [[ "${GITHUB_REF:-refs/heads/main}" != "refs/heads/main" ]]; then
    log::fatal "releases run from main, not ${GITHUB_REF}"
  fi
  tag="$(pending_tag)"
  if [[ -n "${tag}" ]]; then
    log::warn "${tag} is already tagged at this commit but has no GitHub" \
      "Release (an earlier run failed after tagging): releasing it again"
    new_tag="false"
  else
    tag="$(next_tag)"
    new_tag="true"
  fi
  printf 'version=%s\ntag=%s\nnew_tag=%s\n' "${tag#v}" "${tag}" "${new_tag}"
}

main "$@"
