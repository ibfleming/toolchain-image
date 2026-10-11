#!/usr/bin/env bash
# Check that every non-merge commit subject in <base>..<head> follows Conventional Commits
# 1.0.0 with this repo's allowed types (see .claude/CLAUDE.md).
# Usage: check-commits.sh <base-sha> [head-sha]   (an all-zero/empty base checks only head)
set -euo pipefail
base="${1:-}"
head="${2:-HEAD}"

types='feat|fix|build|chore|ci|docs|perf|refactor|revert|style|test'
re="^($types)(\\([a-z0-9][a-z0-9-]*\\))?!?: [^ ].{0,99}\$"

if [[ -z $base || $base =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  range=("$head" -1)
else
  range=("$base..$head")
fi

bad=0
while IFS=$'\t' read -r sha subject; do
  if [[ $subject =~ $re ]]; then
    printf 'ok   %s %s\n' "${sha:0:7}" "$subject"
  else
    printf 'FAIL %s %s\n' "${sha:0:7}" "$subject"
    bad=1
  fi
done < <(git log --no-merges --format='%H%x09%s' "${range[@]}")

if [[ $bad -ne 0 ]]; then
  echo "check-commits: use <type>[(scope)][!]: <description>; types: ${types//|/, }" >&2
fi
exit "$bad"
