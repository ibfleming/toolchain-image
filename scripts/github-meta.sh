#!/usr/bin/env bash
# Print GitHub's web/api/git IPv4 ranges (https://api.github.com/meta), one per line, sorted.
# Uses scripts/github-api.sh (authenticated when a gh login or GH_TOKEN/GITHUB_TOKEN exists).
set -euo pipefail
"$(dirname "$0")/github-api.sh" meta \
  | jq -r '(.web + .api + .git)[] | select(contains(":") | not)' | sort -uV
