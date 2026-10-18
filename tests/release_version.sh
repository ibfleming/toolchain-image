#!/bin/bash
#
# Tests for scripts/release_version.sh, in a throwaway git repository with a
# fake gh: version bumps from Conventional Commits, tag pushes, refusals,
# and re-runs of a release that pushed its tag but failed before publishing.
#
# Usage: tests/release_version.sh  (needs git; runs on the host)

set -euo pipefail

REPO_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly REPO_DIR
readonly SCRIPT="${REPO_DIR}/scripts/release_version.sh"
WORK=""
FAILED=0

# shellcheck source=image/lib/log.sh
source "${REPO_DIR}/image/lib/log.sh"

#######################################
# Record one check.
# Globals:
#   FAILED
# Arguments:
#   Description, then a command; the check passes when it succeeds.
# Outputs:
#   An OK or ERROR line to STDERR.
#######################################
check() {
  local description="$1"
  shift
  if "$@"; then
    log::ok "${description}"
  else
    log::error "${description}"
    FAILED=1
  fi
}

#######################################
# Succeed when a string matches an extended regular expression.
# Arguments:
#   String, regex.
#######################################
matches() {
  [[ "$1" =~ $2 ]]
}

#######################################
# Commit an empty change with a message in the test repository.
# Globals:
#   WORK
# Arguments:
#   Commit message (subject, and optionally a body after a blank line).
#######################################
commit() {
  git -C "${WORK}/repo" commit -q --allow-empty -m "$1"
}

#######################################
# Run release_version.sh in the test repository, as a run from main.
# Globals:
#   WORK, SCRIPT
# Arguments:
#   What the fake gh answers: exists, missing or error; then extra
#   environment assignments.
# Outputs:
#   The script's STDOUT and STDERR, then "rc=<status>".
#######################################
run_version() {
  local gh_answer="$1"
  shift
  local out rc=0
  out="$(cd "${WORK}/repo" && env PATH="${WORK}/bin:${PATH}" \
    FAKE_GH="${gh_answer}" GITHUB_REF=refs/heads/main \
    TOOLCHAIN_LOG_COLOR=never "$@" "${SCRIPT}" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

main() {
  local r
  WORK="$(mktemp -d)"
  trap 'rm -rf -- "${WORK}"' EXIT
  mkdir -p "${WORK}/bin" "${WORK}/repo"
  # A fake gh: `gh release view <tag>` answers as FAKE_GH says.
  cat >"${WORK}/bin/gh" <<'EOF'
#!/bin/bash
case "${FAKE_GH}" in
  exists) exit 0 ;;
  missing) echo "release not found" >&2; exit 1 ;;
  *) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
esac
EOF
  chmod +x "${WORK}/bin/gh"
  git -C "${WORK}/repo" init -q -b main
  git -C "${WORK}/repo" config user.email test@example.com
  git -C "${WORK}/repo" config user.name test

  commit "chore: start"
  r="$(run_version exists)"
  check "no vX.Y.Z tag yet: refuses" matches "${r}" "no vX.Y.Z tag yet.*rc=1"

  git -C "${WORK}/repo" tag v0.1.0
  commit "fix: a bug"
  r="$(run_version exists)"
  check "a fix: patch bump" \
    matches "${r}" $'version=0.1.1\ntag=v0.1.1\nnew_tag=true'
  commit "feat(zsh): a feature"
  r="$(run_version exists)"
  check "a feat: minor bump" matches "${r}" "tag=v0.2.0"
  commit "feat!: a breaking change"
  r="$(run_version exists)"
  check "breaking below 1.0: minor bump" matches "${r}" "tag=v0.2.0"
  git -C "${WORK}/repo" tag v1.0.0
  commit $'fix: y\n\nBREAKING CHANGE: removed x'
  r="$(run_version exists)"
  check "a BREAKING CHANGE footer from 1.0: major bump" \
    matches "${r}" "tag=v2.0.0"

  # HEAD carries the newest tag (an earlier run of this release pushed it).
  git -C "${WORK}/repo" tag v2.0.0
  r="$(run_version missing)"
  check "re-run after the tag push: releases the same version" \
    matches "${r}" $'version=2.0.0\ntag=v2.0.0\nnew_tag=false'
  check "and says why" matches "${r}" "no GitHub Release"
  r="$(run_version exists)"
  check "tagged and released (weekly rebuild): next patch" \
    matches "${r}" $'tag=v2.0.1\nnew_tag=true'
  r="$(run_version error)"
  check "gh fails otherwise: refuses rather than guess" \
    matches "${r}" "can't tell whether v2.0.0.*rc=1"

  r="$(run_version exists GITHUB_REF=refs/heads/feature)"
  check "a run from another branch: refuses" \
    matches "${r}" "not refs/heads/feature.*rc=1"
  r="$(run_version exists GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v3.0.0)"
  check "a tag push: releases that tag" \
    matches "${r}" $'tag=v3.0.0\nnew_tag=false'
  r="$(run_version exists GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v3.0.0-rc.1)"
  check "a tag that isn't vX.Y.Z: refuses" matches "${r}" "not vX.Y.Z.*rc=1"

  return "${FAILED}"
}

main "$@"
